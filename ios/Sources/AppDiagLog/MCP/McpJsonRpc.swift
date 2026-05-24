import Foundation

// MARK: - Constants

let mcpJsonRpcVersion = "2.0"
let mcpProtocolVersion = "2024-11-05"

// MARK: - JSON-RPC 2.0 frames

/// A JSON-RPC 2.0 request or notification. `id` is `nil` for notifications.
struct JsonRpcRequest: Codable, Sendable {
    var jsonrpc: String = mcpJsonRpcVersion
    var id: Int?
    var method: String
    var params: AnyJSON?

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

struct JsonRpcResponse: Codable, Sendable {
    var jsonrpc: String = mcpJsonRpcVersion
    var id: Int?
    var result: AnyJSON?
    var error: JsonRpcError?
}

struct JsonRpcError: Codable, Sendable {
    var code: Int
    var message: String
}

/// Standard JSON-RPC 2.0 / MCP error codes.
enum McpErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let unauthorized = -32000
}

// MARK: - MCP initialize

struct McpClientInfo: Codable, Sendable {
    var name: String
    var version: String
}

struct McpServerInfo: Codable, Sendable {
    var name: String
    var version: String
}

struct McpToolsCapability: Codable, Sendable {
    var listChanged: Bool = false
}

struct McpCapabilities: Codable, Sendable {
    var tools: McpToolsCapability?
}

struct McpInitializeParams: Codable, Sendable {
    var protocolVersion: String = mcpProtocolVersion
    var capabilities: McpCapabilities = .init()
    var clientInfo: McpClientInfo
}

struct McpInitializeResult: Codable, Sendable {
    var protocolVersion: String
    var capabilities: McpCapabilities
    var serverInfo: McpServerInfo
}

// MARK: - MCP tools

struct McpProperty: Codable, Sendable {
    var type: String
    var description: String
}

struct McpToolInputSchema: Codable, Sendable {
    var type: String = "object"
    var properties: [String: McpProperty] = [:]
    var required: [String] = []
}

struct McpTool: Codable, Sendable {
    var name: String
    var description: String
    var inputSchema: McpToolInputSchema
}

struct McpToolsListResult: Codable, Sendable {
    var tools: [McpTool]
}

struct McpToolCallParams: Codable, Sendable {
    var name: String
    var arguments: [String: AnyJSON] = [:]
}

struct McpContent: Codable, Sendable {
    var type: String = "text"
    var text: String
}

struct McpToolResult: Codable, Sendable {
    var content: [McpContent]
    var isError: Bool = false
}

// MARK: - AnyJSON helper

/// Minimal type-erased `Codable` for JSON-RPC `params` / `result` fields.
/// Supports `String`, `Int`, `Double`, `Bool`, `[String: AnyJSON]`, `[AnyJSON]`, and `null`.
///
/// `@unchecked Sendable` is safe here under the convention that `AnyJSON` values are
/// never mutated after initialization. The wrapped collection types (`[String: AnyJSON]`,
/// `[AnyJSON]`) are value types in Swift; callers must not hold and mutate a local copy
/// concurrently with passing it across isolation boundaries.
struct AnyJSON: Codable, @unchecked Sendable {
    let value: Any?

    init(_ value: Any?) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else if let d = try? c.decode([String: AnyJSON].self) {
            value = d
        } else if let a = try? c.decode([AnyJSON].self) {
            value = a
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let f = try? c.decode(Double.self) {
            value = f
        } else if let b = try? c.decode(Bool.self) {
            value = b
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case nil:
            try c.encodeNil()
        case let d as [String: AnyJSON]:
            try c.encode(d)
        case let a as [AnyJSON]:
            try c.encode(a)
        case let s as String:
            try c.encode(s)
        case let i as Int:
            try c.encode(i)
        case let f as Double:
            try c.encode(f)
        case let b as Bool:
            try c.encode(b)
        default:
            try c.encodeNil()
        }
    }

    var stringValue: String? { value as? String }
    var dictValue: [String: AnyJSON]? { value as? [String: AnyJSON] }
}

// MARK: - Encoding helpers

extension JSONEncoder {
    /// Encode `value` and wrap as `AnyJSON` for embedding in JSON-RPC frames.
    func anyJSON<T: Encodable>(_ value: T) throws -> AnyJSON {
        let data = try encode(value)
        let obj = try JSONSerialization.jsonObject(with: data)
        return AnyJSON(obj)
    }
}
