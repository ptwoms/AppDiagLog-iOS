import XCTest
@testable import AppDiagLog

final class EventBufferTests: XCTestCase {

    func testAppendReturnsShouldFlushOnceThresholdReached() async {
        let buffer = EventBuffer(flushThreshold: 3, maxInMemory: 10)

        let r1 = await buffer.append(TestHelpers.makeEnvelope(seq: 1))
        let r2 = await buffer.append(TestHelpers.makeEnvelope(seq: 2))
        let r3 = await buffer.append(TestHelpers.makeEnvelope(seq: 3))

        XCTAssertEqual(r1.shouldFlushOrFalse, false)
        XCTAssertEqual(r2.shouldFlushOrFalse, false)
        XCTAssertEqual(r3.shouldFlushOrFalse, true)
    }

    func testDrainEmptiesBufferAndKeepsCapacity() async {
        let buffer = EventBuffer(flushThreshold: 2, maxInMemory: 5)
        _ = await buffer.append(TestHelpers.makeEnvelope(seq: 1))
        _ = await buffer.append(TestHelpers.makeEnvelope(seq: 2))

        let drained = await buffer.drain()
        XCTAssertEqual(drained.events.count, 2)
        let sizeAfter = await buffer.size()
        XCTAssertEqual(sizeAfter, 0)

        // After drain, new appends succeed immediately.
        _ = await buffer.append(TestHelpers.makeEnvelope(seq: 3))
        let sizeFinal = await buffer.size()
        XCTAssertEqual(sizeFinal, 1)
    }

    func testOverflowDropsEventsAndReportsCount() async {
        let buffer = EventBuffer(flushThreshold: 2, maxInMemory: 2)
        _ = await buffer.append(TestHelpers.makeEnvelope(seq: 1))
        _ = await buffer.append(TestHelpers.makeEnvelope(seq: 2))

        let dropped = await buffer.append(TestHelpers.makeEnvelope(seq: 3))
        guard case .dropped(let total) = dropped else {
            return XCTFail("Expected .dropped result, got \(dropped)")
        }
        XCTAssertEqual(total, 1)
    }

    func testDrainPreservesOrder() async {
        let buffer = EventBuffer(flushThreshold: 100, maxInMemory: 100)
        for i in 1...10 {
            _ = await buffer.append(TestHelpers.makeEnvelope(seq: Int64(i)))
        }
        let drained = await buffer.drain()
        XCTAssertEqual(drained.events.map(\.seq), Array(Int64(1)...Int64(10)))
    }
}

private extension EventBuffer.AppendResult {
    var shouldFlushOrFalse: Bool {
        switch self {
        case .accepted(_, let f): return f
        case .dropped: return false
        }
    }
}
