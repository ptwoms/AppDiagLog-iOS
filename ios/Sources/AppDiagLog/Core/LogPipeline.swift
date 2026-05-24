import Foundation

/// Connects the hot path: public API → RateLimiter → EventFactory → RedactionEngine →
/// EventBuffer → FlushCoordinator → SessionManager.persist.
///
/// Memory model:
///   - `buffer` holds "new since last flush" (bounded, small).
///   - `cumulative` (inside this actor) holds events for the current session so we can
///     re-encrypt the whole session file on every flush. Bounded by maxEventsPerSession.
actor LogPipeline {
    private let config: AppDiagLogConfig
    private let buffer: EventBuffer
    private let rateLimiter: RateLimiter
    private let redaction: RedactionEngine
    private let sessionManager: SessionManager
    private let factory: EventFactory
    private let flusher: FlushCoordinator

    private var cumulative: [EventEnvelope] = []
    private var currentIdForCumulative: String?
    private var droppedForSessionCap: UInt64 = 0

    init(
        config: AppDiagLogConfig,
        buffer: EventBuffer,
        rateLimiter: RateLimiter,
        redaction: RedactionEngine,
        sessionManager: SessionManager,
        factory: EventFactory,
        flusher: FlushCoordinator
    ) {
        self.config = config
        self.buffer = buffer
        self.rateLimiter = rateLimiter
        self.redaction = redaction
        self.sessionManager = sessionManager
        self.factory = factory
        self.flusher = flusher
        self.cumulative.reserveCapacity(config.flushBatchSize)
    }

    /// Entry point from public API. Non-suspending from the caller's perspective: the
    /// AppDiagLog facade wraps this call in `Task.detached(priority: .utility)`.
    func enqueue(event: String, level: LogLevel, props: [String: String]) async {
        guard await rateLimiter.tryAcquire() else { return }
        let envelope = factory.make(event: event, level: level, props: props)
        let redacted = redaction.redact(envelope)

        // Per-session cap
        if cumulative.count >= config.maxEventsPerSession {
            droppedForSessionCap &+= 1
            return
        }

        switch await buffer.append(redacted) {
        case .accepted(_, let shouldFlush):
            if shouldFlush { await flusher.flushNow() }
            else { await flusher.schedule() }
        case .dropped:
            break
        }
    }

    func flushOnce() async {
        let drain = await buffer.drain()
        await syncSessionIfNeeded()

        if !drain.events.isEmpty {
            let spaceLeft = config.maxEventsPerSession - cumulative.count
            if spaceLeft >= drain.events.count {
                cumulative.append(contentsOf: drain.events)
            } else if spaceLeft > 0 {
                cumulative.append(contentsOf: drain.events.prefix(spaceLeft))
                droppedForSessionCap &+= UInt64(drain.events.count - spaceLeft)
            } else {
                droppedForSessionCap &+= UInt64(drain.events.count)
            }
        }
        await sessionManager.persistCurrent(pending: cumulative)
    }

    func shutdown() async {
        await flusher.flushNow()
        await sessionManager.sealCurrent(pending: cumulative)
        cumulative.removeAll(keepingCapacity: true)
        currentIdForCumulative = nil
    }

    func handleSessionRotated() async {
        cumulative.removeAll(keepingCapacity: true)
        currentIdForCumulative = await sessionManager.ensureSession()?.id
        factory.resetForNewSession()
    }

    private func syncSessionIfNeeded() async {
        let active = await sessionManager.ensureSession()?.id
        if active != currentIdForCumulative {
            cumulative.removeAll(keepingCapacity: true)
            currentIdForCumulative = active
            factory.resetForNewSession()
        }
    }
}
