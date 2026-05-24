import Foundation

/// Token bucket rate limiter.
///
/// Not an actor — intentionally. It's a tight hot-path primitive and the internal state
/// is protected by a `DispatchQueue`-free lock-less approach via actor hopping would
/// add unnecessary suspension points. We use a small nested actor to stay in Swift
/// structured concurrency without dispatch queues.
actor RateLimiter {
    private let capacity: Double
    private let refillPerSecond: Double
    private let clock: @Sendable () -> UInt64   // monotonic ns
    private var tokens: Double
    private var lastRefillNs: UInt64
    private(set) var droppedTotal: UInt64 = 0

    init(
        capacity: Int,
        refillPerSecond: Int,
        clock: @Sendable @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.capacity = Double(capacity)
        self.refillPerSecond = Double(refillPerSecond)
        self.clock = clock
        self.tokens = Double(capacity)
        self.lastRefillNs = clock()
    }

    func tryAcquire() -> Bool {
        let now = clock()
        let elapsedSec = Double(now &- lastRefillNs) / 1_000_000_000.0
        if elapsedSec > 0 {
            tokens = min(capacity, tokens + elapsedSec * refillPerSecond)
            lastRefillNs = now
        }
        if tokens >= 1.0 {
            tokens -= 1.0
            return true
        }
        droppedTotal &+= 1
        return false
    }
}
