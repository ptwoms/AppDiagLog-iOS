import XCTest
@testable import AppDiagLog

final class RateLimiterTests: XCTestCase {

    func testWithinBurstAllAccepted() async {
        let limiter = RateLimiter(capacity: 10, refillPerSecond: 10, clock: { 0 })
        var accepted = 0
        for _ in 0..<10 {
            if await limiter.tryAcquire() { accepted += 1 }
        }
        XCTAssertEqual(accepted, 10)
        let eleventh = await limiter.tryAcquire()
        XCTAssertFalse(eleventh, "11th should be dropped")
    }

    func testRefillRestoresCapacityOverTime() async {
        let clock = MutableClock(start: 0)
        let limiter = RateLimiter(capacity: 2, refillPerSecond: 2, clock: clock.read)

        let first = await limiter.tryAcquire()
        let second = await limiter.tryAcquire()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        let exhausted = await limiter.tryAcquire()
        XCTAssertFalse(exhausted, "bucket should be empty")

        // 600ms → 1.2 tokens accumulated → 1 available.
        clock.advance(nanoseconds: 600_000_000)
        let third = await limiter.tryAcquire()
        XCTAssertTrue(third)
        let stillEmpty = await limiter.tryAcquire()
        XCTAssertFalse(stillEmpty, "still <2 tokens accumulated")
    }
}

/// Sendable mutable clock for deterministic tests. NSLock-protected because the limiter
/// invokes `clock` from inside its actor and we read/write it from the test thread.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ns: UInt64

    init(start: UInt64) { self.ns = start }

    func advance(nanoseconds delta: UInt64) {
        lock.lock(); defer { lock.unlock() }
        ns &+= delta
    }

    var read: @Sendable () -> UInt64 {
        { [self] in
            lock.lock(); defer { lock.unlock() }
            return ns
        }
    }
}
