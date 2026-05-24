import Foundation

/// Actor-isolated, bounded, reusable event buffer.
///
/// Memory characteristics:
///  - Backing array is `reserveCapacity`-pre-sized once at init, reused forever.
///  - Drain snapshots into a fresh `[EventEnvelope]` and calls
///    `removeAll(keepingCapacity: true)` — no dealloc cycle.
///  - Overflow drops incoming events and reports a running count.
actor EventBuffer {
    let flushThreshold: Int
    private let maxInMemory: Int
    private var events: [EventEnvelope] = []
    private var overflowCount: UInt64 = 0

    init(flushThreshold: Int, maxInMemory: Int? = nil) {
        self.flushThreshold = flushThreshold
        self.maxInMemory = maxInMemory ?? flushThreshold
        self.events.reserveCapacity(self.maxInMemory)
    }

    enum AppendResult {
        case accepted(size: Int, shouldFlush: Bool)
        case dropped(totalDropped: UInt64)
    }

    struct Drain {
        let events: [EventEnvelope]
        let droppedSinceLastDrain: UInt64
    }

    func append(_ event: EventEnvelope) -> AppendResult {
        if events.count >= maxInMemory {
            overflowCount &+= 1
            return .dropped(totalDropped: overflowCount)
        }
        events.append(event)
        return .accepted(size: events.count, shouldFlush: events.count >= flushThreshold)
    }

    func drain() -> Drain {
        if events.isEmpty { return Drain(events: [], droppedSinceLastDrain: 0) }
        let snapshot = events // COW snapshot
        let dropped = overflowCount
        events.removeAll(keepingCapacity: true)
        overflowCount = 0
        return Drain(events: snapshot, droppedSinceLastDrain: dropped)
    }

    func size() -> Int { events.count }
}
