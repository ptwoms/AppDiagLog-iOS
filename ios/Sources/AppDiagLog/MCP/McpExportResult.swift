import Foundation

/// Result of an MCP-based export via `AppDiagLog.exportViaMcp()`.
public enum McpExportResult: Sendable {
    /// All sessions were successfully submitted to the remote MCP server.
    case success(sessionCount: Int)

    /// Export or remote submission failed.
    case failure(error: Error, message: String)
}
