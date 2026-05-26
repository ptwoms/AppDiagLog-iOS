import Foundation

/// The log-level tags we emit into each envelope.
public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// A single diagnostic event.
///
/// Matches the backend schema exactly. Fields:
/// - `seq`: monotonic per-session log order (combined outputs may rewrite it)
/// - `ts`: ISO-8601 UTC observation timestamp
/// - `props`: always `[String: String]` — no nested objects
public struct EventEnvelope: Codable, Sendable, Equatable {
    public let seq: Int64
    public let ts: String
    public let sessionId: String
    public let screen: String?
    public let event: String
    public let level: LogLevel
    public let props: [String: String]

    public init(
        seq: Int64,
        ts: String,
        sessionId: String,
        screen: String?,
        event: String,
        level: LogLevel,
        props: [String: String]
    ) {
        self.seq = seq
        self.ts = ts
        self.sessionId = sessionId
        self.screen = screen
        self.event = event
        self.level = level
        self.props = props
    }

    enum CodingKeys: String, CodingKey {
        case seq, ts, screen, event, level, props
        case sessionId = "session_id"
    }
}
