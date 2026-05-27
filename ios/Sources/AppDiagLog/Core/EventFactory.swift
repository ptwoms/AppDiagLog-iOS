import Foundation

/// Lock-guarded per-session event sequence. It is shared by the public facade
/// and EventFactory so events created from different threads still get a
/// deterministic order inside the current session.
final class EventSequenceGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: Int64

    init(nextSequence: Int64 = 1) {
        self.nextSequence = max(1, nextSequence)
    }

    func next() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let value = nextSequence
        nextSequence &+= 1
        return value
    }

    func resetForNewSession() {
        lock.lock(); defer { lock.unlock() }
        nextSequence = 1
    }
}

/// Creates event envelopes and formats timestamps.
final class EventFactory: @unchecked Sendable {
    private let sessionIdProvider: @Sendable () -> String?
    private let screenProvider: @Sendable () -> String?
    private let sequenceGenerator: EventSequenceGenerator

    private let isoFormatter = Date.isoDateFormatter

    init(
        sessionIdProvider: @escaping @Sendable () -> String?,
        screenProvider: @escaping @Sendable () -> String?,
        sequenceGenerator: EventSequenceGenerator
    ) {
        self.sessionIdProvider = sessionIdProvider
        self.screenProvider = screenProvider
        self.sequenceGenerator = sequenceGenerator
    }

    func make(
        event: String,
        level: LogLevel,
        props: [String: String],
        observedAt: Date = Date(),
        sequence: Int64? = nil
    ) -> EventEnvelope {
        return EventEnvelope(
            seq: sequence ?? sequenceGenerator.next(),
            ts: isoFormatter.string(from: observedAt),
            sessionId: sessionIdProvider() ?? "pending",
            screen: screenProvider(),
            event: event,
            level: level,
            props: props
        )
    }

    func resetForNewSession() {
        sequenceGenerator.resetForNewSession()
    }
}

/// Thread-safe current-screen tracker.
final class CurrentScreenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ name: String?) { lock.lock(); value = name; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
