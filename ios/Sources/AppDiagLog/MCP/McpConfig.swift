import Foundation

/// Configuration for the Model Context Protocol (MCP) integration.
///
/// MCP allows AI agents to interact with the AppDiagLog SDK either by:
/// - Connecting *to* an on-device MCP server to pull encrypted logs (`.server` mode)
/// - Having the SDK push encrypted logs *to* a remote MCP server (`.client` mode)
///
/// MCP is disabled when `AppDiagLogConfig.mcpConfig` is `nil` (the default).
public enum McpConfig: Sendable {
    /// Run an MCP server on-device. Remote AI agents connect via HTTP to pull
    /// encrypted session data. The server never decrypts on-device.
    ///
    /// - Parameters:
    ///   - port: TCP port to listen on (default 7321).
    ///   - authToken: Bearer token for every incoming request. When `nil`
    ///     (the default) the SDK generates a cryptographically random 256-bit
    ///     token at startup and prints it to the Xcode console so you can copy
    ///     it into your MCP client. A non-nil value is validated to be non-blank
    ///     at server initialisation time.
    ///   - allowedOrigins: CORS allowed `Origin` values. Empty list disables CORS header injection.
    ///   - bindAddress: IP address to bind. Default `"127.0.0.1"` restricts to loopback.
    ///     Use `"0.0.0.0"` for local-network access — requires `NSLocalNetworkUsageDescription`
    ///     in `Info.plist` if advertising via Bonjour, and TLS in production.
    case server(
        port: UInt16 = 7321,
        authToken: String? = nil,
        allowedOrigins: [String] = [],
        bindAddress: String = "127.0.0.1"
    )

    /// Connect to a remote MCP server to submit encrypted logs. The SDK acts as an MCP
    /// client, flushing the session buffer, building the export ZIP, and invoking the
    /// configured tool on the remote server.
    ///
    /// - Parameters:
    ///   - serverUrl: HTTPS URL of the remote MCP endpoint. Plain HTTP URLs are rejected
    ///     at `AppDiagLog.initialize` time to prevent unencrypted transmission.
    ///   - authToken: Bearer token sent with every request.
    ///   - toolName: MCP tool to invoke (default: `"submit_diagnostics"`).
    ///   - timeoutSeconds: URLSession timeout in seconds (default 30).
    case client(
        serverUrl: String,
        authToken: String,
        toolName: String = "submit_diagnostics",
        timeoutSeconds: Int = 30
    )
}
