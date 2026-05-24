import Foundation

/// Debounced flush scheduler — actor-isolated, uses structured concurrency only.
///
/// Behaviour:
///  - `schedule()` sets up a one-shot flush after `debounceMillis`. Re-scheduling
///    before the timer fires resets the delay (so bursts collapse to one flush).
///  - `maxWaitMillis` caps the total wait — even a slow drip eventually flushes.
///  - `flushNow()` cancels the pending task and runs the flush immediately.
///
/// Note: we use `Task.sleep(nanoseconds:)` rather than any dispatch timer — stays
/// within structured concurrency per the project's architecture rules.
actor FlushCoordinator {
    typealias Flusher = @Sendable () async -> Void

    private let debounceMillis: UInt64
    private let maxWaitMillis: UInt64
    private let onFlush: Flusher

    private var pendingTask: Task<Void, Never>?
    private var firstScheduledAt: UInt64 = 0

    init(debounceMillis: UInt64, maxWaitMillis: UInt64, onFlush: @escaping Flusher) {
        self.debounceMillis = debounceMillis
        self.maxWaitMillis = maxWaitMillis
        self.onFlush = onFlush
    }

    func schedule() {
        let nowMs = Self.nowMs()
        if pendingTask == nil {
            firstScheduledAt = nowMs
        }
        let elapsed = nowMs &- firstScheduledAt
        let delay: UInt64 = {
            if elapsed >= maxWaitMillis { return 0 }
            let remaining = maxWaitMillis &- elapsed
            return min(debounceMillis, remaining)
        }()

        pendingTask?.cancel()
        pendingTask = Task.detached(priority: .utility) { [weak self, delay, onFlush] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
            if Task.isCancelled { return }
            await self?.clearPending()
            await onFlush()
        }
    }

    func flushNow() async {
        pendingTask?.cancel()
        pendingTask = nil
        firstScheduledAt = 0
        await onFlush()
    }

    private func clearPending() {
        pendingTask = nil
        firstScheduledAt = 0
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
