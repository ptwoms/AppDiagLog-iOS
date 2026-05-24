import Foundation

/// Atomic counter for monotonic `seq` + shared ISO-8601 formatter.
final class EventFactory: @unchecked Sendable {
    private let sessionIdProvider: @Sendable () -> String?
    private let screenProvider: @Sendable () -> String?
    private let lock = NSLock()
    private var seq: Int64 = 0

    private let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    init(
        sessionIdProvider: @escaping @Sendable () -> String?,
        screenProvider: @escaping @Sendable () -> String?
    ) {
        self.sessionIdProvider = sessionIdProvider
        self.screenProvider = screenProvider
    }

    func resetForNewSession() {
        lock.lock(); defer { lock.unlock() }
        seq = 0
    }

    func make(event: String, level: LogLevel, props: [String: String]) -> EventEnvelope {
        lock.lock()
        seq &+= 1
        let s = seq
        lock.unlock()
        return EventEnvelope(
            seq: s,
            ts: isoFormatter.string(from: Date()),
            sessionId: sessionIdProvider() ?? "pending",
            screen: screenProvider(),
            event: event,
            level: level,
            props: props
        )
    }
}

/// Thread-safe current-screen tracker.
final class CurrentScreenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ name: String?) { lock.lock(); value = name; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
