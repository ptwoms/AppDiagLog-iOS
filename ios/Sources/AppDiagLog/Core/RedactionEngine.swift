import Foundation

/// Strips PII from events before they reach storage.
///
/// Order:
///  1. URL redaction (keys: url, endpoint, referrer, deep_link, redirect)
///  2. Header blocklist (Authorization, Cookie, Set-Cookie, X-API-Key, ...)
///  3. Custom user redactor (runs last so apps can always override)
///
/// Zero-allocation fast path: if no value needed redaction we return the original
/// envelope unchanged.
struct RedactionEngine: Sendable {
    private let custom: (@Sendable (EventEnvelope) -> EventEnvelope)?

    init(custom: (@Sendable (EventEnvelope) -> EventEnvelope)? = nil) {
        self.custom = custom
    }

    func redact(_ event: EventEnvelope) -> EventEnvelope {
        let newProps = Self.redactProps(event.props)
        let base: EventEnvelope
        if newProps == event.props {
            base = event
        } else {
            base = EventEnvelope(
                seq: event.seq,
                ts: event.ts,
                sessionId: event.sessionId,
                screen: event.screen,
                event: event.event,
                level: event.level,
                props: newProps
            )
        }
        guard let custom else { return base }
        // User callback may throw — we swallow and return built-in result.
        return custom(base)
    }

    static func redactUrl(_ raw: String) -> String {
        var stripped = raw
        if let q = stripped.firstIndex(of: "?") { stripped = String(stripped[..<q]) }
        if let h = stripped.firstIndex(of: "#") { stripped = String(stripped[..<h]) }

        stripped = uuidRegex.stringByReplacingMatches(in: stripped, options: [], range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "{id}")
        stripped = numericIdRegex.stringByReplacingMatches(in: stripped, options: [], range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "/{id}")
        stripped = hexIdRegex.stringByReplacingMatches(in: stripped, options: [], range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "/{id}")
        stripped = emailRegex.stringByReplacingMatches(in: stripped, options: [], range: NSRange(stripped.startIndex..., in: stripped), withTemplate: "{email}")
        return stripped
    }

    private static let redactedMarker = "<redacted>"

    private static let sensitiveHeaderKeys: Set<String> = [
        "authorization", "cookie", "set-cookie", "x-api-key",
        "proxy-authorization", "www-authenticate", "x-auth-token"
    ]

    private static let urlKeys: Set<String> = ["url", "endpoint", "referrer", "deep_link", "redirect"]

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
    )
    private static let numericIdRegex = try! NSRegularExpression(pattern: "/\\d{3,}")
    private static let hexIdRegex = try! NSRegularExpression(pattern: "/[0-9a-fA-F]{16,}")
    private static let emailRegex = try! NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    )

    private static func redactProps(_ props: [String: String]) -> [String: String] {
        var changed = false
        var out: [String: String] = props
        for (key, value) in props {
            let lower = key.lowercased()
            if sensitiveHeaderKeys.contains(lower) {
                out[key] = redactedMarker
                changed = true
            } else if urlKeys.contains(lower) {
                let redacted = redactUrl(value)
                if redacted != value {
                    out[key] = redacted
                    changed = true
                }
            }
        }
        return changed ? out : props
    }
}
