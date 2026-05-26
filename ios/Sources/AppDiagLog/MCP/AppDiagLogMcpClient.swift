import Foundation

/// MCP client that submits encrypted sessions to a remote MCP server.
///
/// Protocol flow:
///  1. Flush pending events.
///  2. Build the export ZIP via `ExportManager`.
///  3. POST `initialize` to perform the MCP handshake.
///  4. POST `notifications/initialized` (fire-and-forget).
///  5. POST `tools/call` with the configured tool name and base64-encoded ZIP.
///
/// HTTPS is enforced at `AppDiagLog.initialize` time via `McpConfig.client` validation.
/// Uses `URLSession` — no additional library dependency.
actor AppDiagLogMcpClient {
    private let config: McpConfig
    private let pipeline: LogPipeline
    private let exportManager: ExportManager
    private let sdkVersion: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let session: URLSession

    private enum Constants {
        /// URLSession resource timeout is a multiple of the per-request timeout to allow for
        /// slow uploads (the ZIP can be several MB) while still bounding total time.
        /// Effective resource timeout = `timeoutSeconds * resourceTimeoutMultiplier`.
        static let resourceTimeoutMultiplier = 2
    }

    init(
        config: McpConfig,
        pipeline: LogPipeline,
        exportManager: ExportManager,
        sdkVersion: String
    ) {
        self.config = config
        self.pipeline = pipeline
        self.exportManager = exportManager
        self.sdkVersion = sdkVersion
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()

        // Dedicated session with configured timeout.
        let urlConfig = URLSessionConfiguration.ephemeral
        if case let .client(_, _, _, timeoutSeconds) = config {
            urlConfig.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
            urlConfig.timeoutIntervalForResource = TimeInterval(timeoutSeconds * Constants.resourceTimeoutMultiplier)
        }
        self.session = URLSession(configuration: urlConfig)
    }

    func exportViaMcp() async -> McpExportResult {
        guard case let .client(serverUrl, authToken, toolName, _) = config else {
            return .failure(error: McpClientError.misconfigured, message: "McpConfig.client required")
        }

        // Step 1: flush pending events.
        await pipeline.flushOnce()

        // Step 2: build export ZIP.
        let exportResult = await exportManager.export()
        let (zipData, sessionCount): (Data, Int)
        switch exportResult {
        case .success(let file, let count, _):
            guard let bytes = try? Data(contentsOf: file) else {
                return .failure(error: McpClientError.exportFailed, message: "Failed to read export file")
            }
            zipData = bytes
            sessionCount = count
        case .failure(let err, let msg):
            return .failure(error: err, message: msg)
        }

        // Step 3: MCP initialize handshake.
        let initParams = McpInitializeParams(
            clientInfo: McpClientInfo(name: "AppDiagLogSDK", version: sdkVersion)
        )
        guard let initRequest = makeRequest(id: 1, method: "initialize", params: initParams) else {
            return .failure(error: McpClientError.encodingFailed, message: "Failed to encode initialize request")
        }
        do {
            let initResponse = try await post(request: initRequest, to: serverUrl, bearer: authToken)
            if let err = initResponse.error {
                return .failure(error: McpClientError.remoteError(err.code), message: "MCP initialize failed: \(err.message)")
            }
        } catch {
            return .failure(error: error, message: "MCP initialize request failed: \(error.localizedDescription)")
        }

        // Step 4: send initialized notification (fire-and-forget).
        if let notif = try? encoder.encode(JsonRpcRequest(method: "notifications/initialized")) {
            _ = try? await postRaw(body: notif, to: serverUrl, bearer: authToken)
        }

        // Step 5: tools/call with the export ZIP as base64.
        let encoded = zipData.base64EncodedString()
        let callParams = McpToolCallParams(
            name: toolName,
            arguments: ["data": AnyJSON(encoded)]
        )
        guard let callRequest = makeRequest(id: 2, method: "tools/call", params: callParams) else {
            return .failure(error: McpClientError.encodingFailed, message: "Failed to encode tools/call request")
        }
        do {
            let callResponse = try await post(request: callRequest, to: serverUrl, bearer: authToken)
            if let err = callResponse.error {
                return .failure(error: McpClientError.remoteError(err.code), message: "MCP tool call failed: \(err.message)")
            }
            // Check if the tool itself signalled an error.
            if let resultJSON = callResponse.result,
               let resultData = try? encoder.encode(resultJSON),
               let toolResult = try? decoder.decode(McpToolResult.self, from: resultData),
               toolResult.isError {
                let msg = toolResult.content.first?.text ?? "Tool returned error"
                return .failure(error: McpClientError.toolError, message: msg)
            }
        } catch {
            return .failure(error: error, message: "MCP tool call failed: \(error.localizedDescription)")
        }

        return .success(sessionCount: sessionCount)
    }

    // MARK: - HTTP helpers

    private func makeRequest<P: Encodable>(id: Int?, method: String, params: P) -> Data? {
        guard let paramsJSON = try? encoder.anyJSON(params) else { return nil }
        var req = JsonRpcRequest(method: method, params: paramsJSON)
        req.id = id.map(JsonRpcID.int)
        return try? encoder.encode(req)
    }

    private func post(request: Data, to urlString: String, bearer: String) async throws -> JsonRpcResponse {
        let data = try await postRaw(body: request, to: urlString, bearer: bearer)
        return try decoder.decode(JsonRpcResponse.self, from: data)
    }

    @discardableResult
    private func postRaw(body: Data, to urlString: String, bearer: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw McpClientError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = body

        let (data, _) = try await session.data(for: urlRequest)
        return data
    }

    // MARK: - Errors

    enum McpClientError: Error {
        case misconfigured
        case exportFailed
        case encodingFailed
        case invalidURL
        case toolError
        case remoteError(Int)
    }
}
