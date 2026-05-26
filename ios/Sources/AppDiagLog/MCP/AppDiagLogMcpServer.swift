import Foundation
import Network
import Security

/// MCP-over-HTTP server running on-device via Network.framework (`NWListener`).
///
/// Agents connect to `http://<bindAddress>:<port>/mcp` and use the JSON-RPC 2.0
/// MCP protocol to:
///  - Perform the `initialize` handshake
///  - List tools via `tools/list`
///  - Call `list_sessions`, `export_sessions`, `get_session_count`, or `tag_session`
///    via `tools/call`
///
/// All session data returned is encrypted — the server never decrypts on-device.
/// Every request must carry `Authorization: Bearer <authToken>`.
actor AppDiagLogMcpServer {
    private let config: McpConfig
    private let indexStore: SessionIndexStore
    private let exportManager: ExportManager
    private let pipeline: LogPipeline
    private let sessionManager: SessionManager
    private let sdkVersion: String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// The effective auth token for this server instance. When `McpConfig.server(authToken:)`
    /// was provided it equals that value; otherwise it is a cryptographically random 256-bit
    /// token generated at initialisation time (printed to the console as a banner).
    ///
    /// Declared `nonisolated` so callers can read it synchronously without `await`.
    nonisolated let token: String

    private var listener: NWListener?
    private var running = false

    /// Cached export file from the most recent `chunk_index == 0` call.
    private var lastExportFile: URL?
    private var lastExportSessionCount: Int = 0

    private enum Constants {
        static let maxRequestSizeBytes = 4 * 1024 * 1024 // 4 MB upper bound on MCP request bodies
        static let receiveChunkSize = 65536 // Single-read buffer for NWConnection receive
    }

    init(
        config: McpConfig,
        indexStore: SessionIndexStore,
        exportManager: ExportManager,
        pipeline: LogPipeline,
        sessionManager: SessionManager,
        sdkVersion: String
    ) {
        // Resolve the effective token before initialising any other stored property.
        if case let .server(_, authToken, _, _) = config, let provided = authToken {
            precondition(
                !provided.trimmingCharacters(in: .whitespaces).isEmpty,
                "McpConfig.server authToken must not be blank when provided"
            )
            token = provided
        } else {
            let generated = AppDiagLogMcpServer.generateToken()
            AppDiagLogMcpServer.printTokenBanner(generated)
            token = generated
        }

        self.config = config
        self.indexStore = indexStore
        self.exportManager = exportManager
        self.pipeline = pipeline
        self.sessionManager = sessionManager
        self.sdkVersion = sdkVersion
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    // MARK: - Token generation

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02hhx", $0) }.joined()
    }

    private static func printTokenBanner(_ token: String) {
        let sep = "================================================================"
        print(sep)
        print("  AppDiagLog MCP — token (auto-generated, valid until restart)")
        print("")
        print("  \(token)")
        print("")
        print("  Set this as the Authorization header:")
        print("    Authorization: Bearer \(token)")
        print("")
        print("  To use a fixed token, pass authToken to McpConfig.server(...).")
        print(sep)
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        guard case let .server(port, _, _, _) = config else { return }

        let tcp = NWParameters.tcp
        tcp.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 7321

        guard let lst = try? NWListener(using: tcp, on: nwPort) else {
            SdkLog.warn("MCP server: failed to create NWListener on port \(port)")
            return
        }
        listener = lst
        running = true

        lst.newConnectionHandler = { [weak self] connection in
            Task.detached(priority: .utility) {
                await self?.handleConnection(connection)
            }
        }

        lst.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                SdkLog.info("MCP server: listening on port \(port)")
            case .failed(let err):
                SdkLog.warn("MCP server: listener failed — \(err)")
                Task { await self?.stop() }
            case .cancelled:
                break
            default:
                break
            }
        }

        lst.start(queue: .global(qos: .utility))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        do {
            let requestData = try await receiveData(connection)
            guard let httpRequest = parseHTTP(requestData) else {
                connection.cancel()
                return
            }
            let response = await processRequest(httpRequest)
            let responseData = buildHTTPResponse(response)
            await send(responseData, on: connection)
        } catch {
            SdkLog.warn("MCP connection error: \(error)")
        }
        connection.cancel()
    }

    // MARK: - Data receive / send

    /// Accumulate data from the connection until we have a complete HTTP request
    /// (header section terminated by `\r\n\r\n`) plus any declared body bytes.
    private func receiveData(_ connection: NWConnection) async throws -> Data {
        var accumulated = Data()
        while true {
            let chunk = try await receiveChunk(connection)
            guard !chunk.isEmpty else { break }
            accumulated.append(chunk)

            // Check if we have the full HTTP message.
            if isCompleteHTTPRequest(accumulated) { break }

            // Bail out if we've received more data than the safety cap.
            if accumulated.count > Constants.maxRequestSizeBytes { break }
        }
        return accumulated
    }

    private func receiveChunk(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Constants.receiveChunkSize) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if isComplete && (data == nil || data!.isEmpty) { cont.resume(returning: Data()); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    /// Returns true once `data` contains a complete HTTP/1.1 request:
    /// header block ending in `\r\n\r\n` (or `\n\n`) and the declared body.
    private func isCompleteHTTPRequest(_ data: Data) -> Bool {
        guard let boundary = headerBoundary(in: data),
              let headerSection = String(data: data.prefix(boundary.headerEnd), encoding: .utf8) else {
            return false
        }
        let headers = headerSection.components(separatedBy: boundary.lineBreak)
        for line in headers {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let lenStr = lower.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                let declared = Int(lenStr) ?? 0
                return data.count >= boundary.bodyStart + declared
            }
        }
        return true // no Content-Length → body is empty
    }

    private func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in
                cont.resume()
            })
        }
    }

    // MARK: - HTTP parsing

    private struct HttpRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private struct HttpResponse {
        let status: Int
        let statusText: String
        let contentType: String
        let body: Data
        var extraHeaders: [String: String] = [:]
    }

    private func parseHTTP(_ data: Data) -> HttpRequest? {
        guard let boundary = headerBoundary(in: data),
              let headerSection = String(data: data.prefix(boundary.headerEnd), encoding: .utf8) else {
            return nil
        }

        var lines = headerSection.components(separatedBy: boundary.lineBreak)
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = requestLine[0]
        let path = requestLine[1]

        var headers: [String: String] = [:]
        for line in lines {
            let colon = line.firstIndex(of: ":")
            if let c = colon {
                let key = String(line[line.startIndex..<c]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyData: Data
        if contentLength > 0 {
            bodyData = Data(data.dropFirst(boundary.bodyStart).prefix(contentLength))
        } else {
            bodyData = Data()
        }

        return HttpRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func headerBoundary(in data: Data) -> (headerEnd: Int, bodyStart: Int, lineBreak: String)? {
        let crlf = Data("\r\n\r\n".utf8)
        if let range = data.range(of: crlf) {
            return (range.lowerBound, range.upperBound, "\r\n")
        }
        let lf = Data("\n\n".utf8)
        if let range = data.range(of: lf) {
            return (range.lowerBound, range.upperBound, "\n")
        }
        return nil
    }

    // MARK: - Request dispatch

    private func processRequest(_ req: HttpRequest) async -> HttpResponse {
        // CORS preflight.
        if req.method == "OPTIONS" {
            return HttpResponse(status: 204, statusText: "No Content", contentType: "text/plain",
                                body: Data(), extraHeaders: corsHeaders(for: req))
        }

        // Auth check (constant-time).
        guard case .server = config else {
            return errorResponse(nil, McpErrorCode.internalError, "Server config missing", request: req)
        }
        // RFC 7235 §2.1: auth-scheme is case-insensitive; the Bearer token is case-sensitive.
        let authHeader = (req.headers["authorization"] ?? "")
        let provided: String
        if authHeader.lowercased().hasPrefix("bearer ") {
            provided = String(authHeader.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        } else {
            provided = authHeader.trimmingCharacters(in: .whitespaces)
        }
        guard constantTimeEquals(provided, token) else {
            return errorResponse(nil, McpErrorCode.unauthorized, "Unauthorized", request: req)
        }

        guard req.method == "POST", req.path == "/mcp" else {
            return errorResponse(nil, McpErrorCode.methodNotFound, "Use POST /mcp", request: req)
        }

        guard let rpcRequest = try? decoder.decode(JsonRpcRequest.self, from: req.body) else {
            return errorResponse(nil, McpErrorCode.parseError, "Invalid JSON-RPC request", request: req)
        }

        let responseBody = await dispatch(rpcRequest)
        if responseBody.isEmpty {
            return HttpResponse(status: 204, statusText: "No Content", contentType: "application/json",
                                body: Data(), extraHeaders: corsHeaders(for: req))
        }
        return HttpResponse(status: 200, statusText: "OK", contentType: "application/json",
                            body: responseBody, extraHeaders: corsHeaders(for: req))
    }

    private func dispatch(_ req: JsonRpcRequest) async -> Data {
        switch req.method {
        case "initialize":
            return handleInitialize(req)
        case "notifications/initialized":
            return Data() // fire-and-forget
        case "tools/list":
            return handleToolsList(req)
        case "tools/call":
            return await handleToolsCall(req)
        default:
            return encodeResponse(JsonRpcResponse(
                id: req.id,
                error: JsonRpcError(code: McpErrorCode.methodNotFound, message: "Unknown method: \(req.method)")
            ))
        }
    }

    // MARK: - MCP handlers

    private func handleInitialize(_ req: JsonRpcRequest) -> Data {
        let result = McpInitializeResult(
            protocolVersion: mcpProtocolVersion,
            capabilities: McpCapabilities(tools: McpToolsCapability()),
            serverInfo: McpServerInfo(name: "AppDiagLogSDK", version: sdkVersion)
        )
        return encodeResponse(JsonRpcResponse(id: req.id, result: try? encoder.anyJSON(result)))
    }

    private func handleToolsList(_ req: JsonRpcRequest) -> Data {
        let tools = McpToolsListResult(tools: [
            McpTool(name: "list_sessions",
                    description: "List recorded session metadata. Returns encrypted-session metadata only — no event content.",
                    inputSchema: McpToolInputSchema()),
            McpTool(name: "export_sessions",
                    description: "Flush pending events and export all sessions as a chunked base64-encoded encrypted ZIP archive. " +
                                 "Optional: chunk_index (int, 0-based, default 0; index 0 triggers a fresh export), " +
                                 "chunk_size_bytes (int, default 2097152, max 8388608). " +
                                 "Iterate chunk_index from 0 to total_chunks-1 to retrieve the full archive.",
                    inputSchema: McpToolInputSchema(
                        properties: [
                            "chunk_index": McpProperty(type: "integer", description: "Zero-based chunk index. Use 0 to start a fresh export."),
                            "chunk_size_bytes": McpProperty(type: "integer", description: "Bytes per chunk (default 2 MB, max 8 MB)."),
                        ]
                    )),
            McpTool(name: "get_session_count",
                    description: "Return the number of stored sessions.",
                    inputSchema: McpToolInputSchema()),
            McpTool(name: "tag_session",
                    description: "Attach a human-readable label to the current session for triage.",
                    inputSchema: McpToolInputSchema(
                        properties: ["label": McpProperty(type: "string", description: "Label to attach to the current session.")],
                        required: ["label"]
                    )),
        ])
        return encodeResponse(JsonRpcResponse(id: req.id, result: try? encoder.anyJSON(tools)))
    }

    private func handleToolsCall(_ req: JsonRpcRequest) async -> Data {
        guard let paramsJSON = req.params,
              let paramsData = try? encoder.encode(paramsJSON),
              let params = try? decoder.decode(McpToolCallParams.self, from: paramsData) else {
            return encodeResponse(JsonRpcResponse(
                id: req.id,
                error: JsonRpcError(code: McpErrorCode.invalidParams, message: "Invalid tools/call params")
            ))
        }

        let toolResult: McpToolResult
        switch params.name {
        case "list_sessions":
            toolResult = await toolListSessions()
        case "export_sessions":
            toolResult = await toolExportSessions(params)
        case "get_session_count":
            toolResult = await toolGetSessionCount()
        case "tag_session":
            toolResult = await toolTagSession(params)
        default:
            toolResult = McpToolResult(content: [McpContent(text: "Unknown tool: \(params.name)")], isError: true)
        }
        return encodeResponse(JsonRpcResponse(id: req.id, result: try? encoder.anyJSON(toolResult)))
    }

    // MARK: - Tool result types (encoded via JSONEncoder to ensure safe escaping)

    private struct SessionSummary: Codable {
        let id: String
        let createdAt: String
        let sealed: Bool
        let eventCount: Int
        let tag: String?
        private enum CodingKeys: String, CodingKey {
            case id, sealed, tag
            case createdAt = "created_at"
            case eventCount = "event_count"
        }
    }

    private struct SessionListResult: Codable {
        let sessions: [SessionSummary]
    }

    private struct ExportSessionsResult: Codable {
        let sessionCount: Int
        let totalSizeBytes: Int64
        let chunkSizeBytes: Int
        let totalChunks: Int
        let chunkIndex: Int
        let data: String
        private enum CodingKeys: String, CodingKey {
            case sessionCount = "session_count"
            case totalSizeBytes = "total_size_bytes"
            case chunkSizeBytes = "chunk_size_bytes"
            case totalChunks = "total_chunks"
            case chunkIndex = "chunk_index"
            case data
        }
    }

    private struct TagSessionResult: Codable {
        let tagged: Bool
        let label: String
    }

    private struct SessionCountResult: Codable {
        let sessionCount: Int
        private enum CodingKeys: String, CodingKey {
            case sessionCount = "session_count"
        }
    }

    // MARK: - Tool implementations

    private func toolListSessions() async -> McpToolResult {
        let index = await indexStore.load()
        let sessions = index.sessions.map { s in
            SessionSummary(id: s.id, createdAt: s.createdAt, sealed: s.sealed,
                           eventCount: s.eventCount, tag: s.sessionTag)
        }
        let result = SessionListResult(sessions: sessions)
        let text = (try? String(data: encoder.encode(result), encoding: .utf8)) ?? "{\"sessions\":[]}"
        return McpToolResult(content: [McpContent(text: text)])
    }

    private func toolExportSessions(_ params: McpToolCallParams) async -> McpToolResult {
        let defaultChunkSize = 2 * 1024 * 1024
        let maxChunkSize = 8 * 1024 * 1024

        let rawChunkIndex = params.arguments["chunk_index"]?.value
        let chunkIndex = (rawChunkIndex as? Int) ?? (rawChunkIndex as? Double).map(Int.init) ?? 0

        let rawChunkSize = params.arguments["chunk_size_bytes"]?.value
        let chunkSizeBytes = max(1, min(maxChunkSize,
            (rawChunkSize as? Int) ?? (rawChunkSize as? Double).map(Int.init) ?? defaultChunkSize))

        let exportFile: URL
        let sessionCount: Int

        if chunkIndex == 0 {
            await pipeline.flushOnce()
            let result = await exportManager.export()
            switch result {
            case .success(let file, let count, _):
                exportFile = file
                sessionCount = count
                lastExportFile = file
                lastExportSessionCount = count
            case .failure(_, let message):
                return McpToolResult(content: [McpContent(text: "Export failed: \(message)")], isError: true)
            }
        } else {
            guard let file = lastExportFile else {
                return McpToolResult(
                    content: [McpContent(text: "No cached export. Call export_sessions with chunk_index=0 first.")],
                    isError: true)
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                return McpToolResult(
                    content: [McpContent(text: "Export file no longer exists. Call export_sessions with chunk_index=0 to re-export.")],
                    isError: true)
            }
            exportFile = file
            sessionCount = lastExportSessionCount
        }

        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: exportFile.path)
            guard let totalSize = attrs[.size] as? Int64, totalSize > 0 else {
                return McpToolResult(
                    content: [McpContent(text: "Unable to determine export file size.")],
                    isError: true)
            }
            let totalChunks = max(1, Int((totalSize + Int64(chunkSizeBytes) - 1) / Int64(chunkSizeBytes)))

            guard chunkIndex < totalChunks else {
                return McpToolResult(
                    content: [McpContent(text: "chunk_index \(chunkIndex) out of range (total_chunks=\(totalChunks))")],
                    isError: true)
            }

            let offset = Int64(chunkIndex) * Int64(chunkSizeBytes)
            let length = Int(min(Int64(chunkSizeBytes), totalSize - offset))

            let handle = try FileHandle(forReadingFrom: exportFile)
            // autoreleasepool prevents transient ObjC bridging allocations from the
            // FileHandle read accumulating until the next GC pass.
            let chunk: Data = autoreleasepool {
                handle.seek(toFileOffset: UInt64(offset))
                return handle.readData(ofLength: length)
            }
            try? handle.close()

            let encoded = chunk.base64EncodedString()
            let payload = ExportSessionsResult(
                sessionCount: sessionCount,
                totalSizeBytes: totalSize,
                chunkSizeBytes: length,
                totalChunks: totalChunks,
                chunkIndex: chunkIndex,
                data: encoded
            )
            let text = (try? String(data: encoder.encode(payload), encoding: .utf8)) ?? "{}"
            return McpToolResult(content: [McpContent(text: text)])
        } catch {
            return McpToolResult(
                content: [McpContent(text: "Error reading chunk: \(error.localizedDescription)")],
                isError: true)
        }
    }

    private func toolGetSessionCount() async -> McpToolResult {
        let index = await indexStore.load()
        let payload = SessionCountResult(sessionCount: index.sessions.count)
        let text = (try? String(data: encoder.encode(payload), encoding: .utf8)) ?? "{}"
        return McpToolResult(content: [McpContent(text: text)])
    }

    private func toolTagSession(_ params: McpToolCallParams) async -> McpToolResult {
        guard let labelJSON = params.arguments["label"],
              let label = labelJSON.stringValue else {
            return McpToolResult(content: [McpContent(text: "Missing required argument: label")], isError: true)
        }
        await sessionManager.tagSession(label)
        let payload = TagSessionResult(tagged: true, label: label)
        let text = (try? String(data: encoder.encode(payload), encoding: .utf8)) ?? "{}"
        return McpToolResult(content: [McpContent(text: text)])
    }

    // MARK: - HTTP response building

    private func errorResponse(_ id: JsonRpcID?, _ code: Int, _ message: String, request: HttpRequest? = nil) -> HttpResponse {
        let body = encodeResponse(JsonRpcResponse(id: id, error: JsonRpcError(code: code, message: message)))
        let extraHeaders = request.map(corsHeaders(for:)) ?? [:]
        return HttpResponse(status: code == McpErrorCode.unauthorized ? 401 : 400,
                            statusText: code == McpErrorCode.unauthorized ? "Unauthorized" : "Bad Request",
                            contentType: "application/json", body: body, extraHeaders: extraHeaders)
    }

    private func buildHTTPResponse(_ response: HttpResponse) -> Data {
        var header = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        header += "Content-Type: \(response.contentType); charset=utf-8\r\n"
        header += "Content-Length: \(response.body.count)\r\n"
        header += "Connection: close\r\n"
        for (k, v) in response.extraHeaders { header += "\(k): \(v)\r\n" }
        header += "\r\n"
        var data = header.data(using: .utf8) ?? Data()
        data.append(response.body)
        return data
    }

    private func corsHeaders(for request: HttpRequest) -> [String: String] {
        guard case let .server(_, _, allowedOrigins, _) = config, !allowedOrigins.isEmpty else {
            return [:]
        }
        let requestOrigin = request.headers["origin"]
        let allowOrigin: String
        if allowedOrigins.contains("*") {
            allowOrigin = "*"
        } else if let requestOrigin, allowedOrigins.contains(requestOrigin) {
            allowOrigin = requestOrigin
        } else {
            return [:]
        }
        return [
            "Access-Control-Allow-Origin": allowOrigin,
            "Access-Control-Allow-Methods": "POST, OPTIONS",
            "Access-Control-Allow-Headers": request.headers["access-control-request-headers"] ?? "Content-Type, Authorization, MCP-Protocol-Version, MCP-Session-Id",
            "Access-Control-Expose-Headers": "MCP-Protocol-Version, MCP-Session-Id",
        ]
    }

    // MARK: - Helpers

    private func encodeResponse(_ response: JsonRpcResponse) -> Data {
        (try? encoder.encode(response)) ?? Data()
    }

    /// Constant-time string equality to resist timing-based token leakage.
    ///
    /// Iterates over `max(a.utf8.count, b.utf8.count)` rather than returning early on
    /// a length mismatch, so the response time does not reveal the expected token length.
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        let maxLen = max(ab.count, bb.count)
        // Accumulate length difference so a mismatch is captured without short-circuiting.
        var diff = ab.count ^ bb.count
        for i in 0..<maxLen {
            let av: UInt8 = i < ab.count ? ab[i] : 0
            let bv: UInt8 = i < bb.count ? bb[i] : 0
            diff |= Int(av ^ bv)
        }
        return diff == 0
    }
}
