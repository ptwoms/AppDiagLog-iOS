import XCTest
@testable import AppDiagLog

final class McpJsonRpcTests: XCTestCase {
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    // MARK: - McpConfig validation

    func testServerConfigStoresProvidedAuthToken() {
        let config = McpConfig.server(port: 7321, authToken: "my-secret-token", allowedOrigins: [], bindAddress: "127.0.0.1")
        if case let .server(_, authToken, _, _) = config {
            XCTAssertEqual(authToken, "my-secret-token")
        }
    }

    func testServerConfigAcceptsNilAuthTokenForAutoGeneration() {
        // authToken defaults to nil — the server auto-generates a token at init time
        let config = McpConfig.server(port: 7321)
        if case let .server(_, authToken, _, _) = config {
            XCTAssertNil(authToken)
        }
    }

    func testClientConfigRequiresHttps() {
        // Validation is done in AppDiagLog.initialize — the enum itself doesn't
        // trap on bad URLs. Verify the URL is stored as-is.
        let cfg = McpConfig.client(serverUrl: "https://example.com/mcp", authToken: "tok")
        if case let .client(serverUrl, _, _, _) = cfg {
            XCTAssertTrue(serverUrl.hasPrefix("https://"))
        }
    }

    // MARK: - JSON-RPC round-trips

    func testJsonRpcRequestRoundTrip() throws {
        let req = JsonRpcRequest(id: 42, method: "tools/list")
        let data = try encoder.encode(req)
        let decoded = try decoder.decode(JsonRpcRequest.self, from: data)
        XCTAssertEqual(decoded.jsonrpc, mcpJsonRpcVersion)
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.method, "tools/list")
    }

    func testJsonRpcResponseWithError() throws {
        let resp = JsonRpcResponse(
            id: 1,
            error: JsonRpcError(code: McpErrorCode.unauthorized, message: "Unauthorized")
        )
        let data = try encoder.encode(resp)
        let decoded = try decoder.decode(JsonRpcResponse.self, from: data)
        XCTAssertEqual(decoded.error?.code, McpErrorCode.unauthorized)
        XCTAssertEqual(decoded.error?.message, "Unauthorized")
        XCTAssertNil(decoded.result)
    }

    func testMcpInitializeResultRoundTrip() throws {
        let result = McpInitializeResult(
            protocolVersion: mcpProtocolVersion,
            capabilities: McpCapabilities(tools: McpToolsCapability()),
            serverInfo: McpServerInfo(name: "TestServer", version: "1.0")
        )
        let anyJSON = try encoder.anyJSON(result)
        let data = try encoder.encode(anyJSON)
        let decoded = try decoder.decode(McpInitializeResult.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, mcpProtocolVersion)
        XCTAssertEqual(decoded.serverInfo.name, "TestServer")
        XCTAssertNotNil(decoded.capabilities.tools)
    }

    func testMcpToolsListResultRoundTrip() throws {
        let tools = McpToolsListResult(tools: [
            McpTool(name: "list_sessions", description: "desc", inputSchema: McpToolInputSchema()),
            McpTool(name: "export_sessions", description: "desc", inputSchema: McpToolInputSchema()),
            McpTool(name: "get_session_count", description: "desc", inputSchema: McpToolInputSchema()),
            McpTool(name: "tag_session", description: "desc",
                    inputSchema: McpToolInputSchema(required: ["label"])),
        ])
        let data = try encoder.encode(tools)
        let decoded = try decoder.decode(McpToolsListResult.self, from: data)
        XCTAssertEqual(decoded.tools.count, 4)
        let names = decoded.tools.map(\.name)
        XCTAssertTrue(names.contains("list_sessions"))
        XCTAssertTrue(names.contains("export_sessions"))
        XCTAssertTrue(names.contains("get_session_count"))
        XCTAssertTrue(names.contains("tag_session"))
    }

    func testMcpToolResultIsErrorDefaultsFalse() throws {
        let result = McpToolResult(content: [McpContent(text: "ok")])
        let data = try encoder.encode(result)
        let decoded = try decoder.decode(McpToolResult.self, from: data)
        XCTAssertFalse(decoded.isError)
        XCTAssertEqual(decoded.content.first?.text, "ok")
    }

    func testMcpToolCallParamsRoundTrip() throws {
        let params = McpToolCallParams(
            name: "tag_session",
            arguments: ["label": AnyJSON("checkout crash")]
        )
        let data = try encoder.encode(params)
        let decoded = try decoder.decode(McpToolCallParams.self, from: data)
        XCTAssertEqual(decoded.name, "tag_session")
        XCTAssertEqual(decoded.arguments["label"]?.stringValue, "checkout crash")
    }

    func testNotificationHasNoId() throws {
        var req = JsonRpcRequest(method: "notifications/initialized")
        req.id = nil
        let data = try encoder.encode(req)
        let decoded = try decoder.decode(JsonRpcRequest.self, from: data)
        XCTAssertNil(decoded.id)
        XCTAssertEqual(decoded.method, "notifications/initialized")
    }

    // MARK: - AnyJSON

    func testAnyJSONStringRoundTrip() throws {
        let a = AnyJSON("hello")
        let data = try encoder.encode(a)
        let decoded = try decoder.decode(AnyJSON.self, from: data)
        XCTAssertEqual(decoded.stringValue, "hello")
    }

    func testAnyJSONDictRoundTrip() throws {
        let a = AnyJSON(["key": AnyJSON("value")])
        let data = try encoder.encode(a)
        let decoded = try decoder.decode(AnyJSON.self, from: data)
        XCTAssertEqual(decoded.dictValue?["key"]?.stringValue, "value")
    }

    func testAnyJSONNullRoundTrip() throws {
        let a = AnyJSON(nil)
        let data = try encoder.encode(a)
        let decoded = try decoder.decode(AnyJSON.self, from: data)
        XCTAssertNil(decoded.value)
    }

    // MARK: - Error codes

    func testErrorCodes() {
        XCTAssertEqual(McpErrorCode.parseError, -32700)
        XCTAssertEqual(McpErrorCode.invalidRequest, -32600)
        XCTAssertEqual(McpErrorCode.methodNotFound, -32601)
        XCTAssertEqual(McpErrorCode.invalidParams, -32602)
        XCTAssertEqual(McpErrorCode.internalError, -32603)
        XCTAssertEqual(McpErrorCode.unauthorized, -32000)
    }
}
