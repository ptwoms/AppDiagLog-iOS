import Foundation
import Network

/// Records connectivity transitions (reachable/unreachable + transport) via NWPathMonitor.
///
/// Uses `pathUpdateHandler` on a detached task — NWPathMonitor requires a DispatchQueue
/// for delivery; we explicitly use a utility-QoS non-concurrent dispatch queue here
/// because `NWPathMonitor.start(queue:)` demands one. This is the SDK's sole remaining
/// GCD touchpoint and is isolated to one callback site that just forwards into the
/// structured-concurrency pipeline.
final class ConnectivityTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime
    private let monitor = NWPathMonitor()
    // Dispatch queue is mandated by NWPathMonitor.start(queue:) — kept low QoS.
    private let deliveryQueue = DispatchQueue(label: "com.appdiaglog.connectivity", qos: .utility)
    private let lock = NSLock()
    private var lastState: String?

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePath(path)
        }
        monitor.start(queue: deliveryQueue)
    }

    func stop() async {
        monitor.cancel()
    }

    private func handlePath(_ path: NWPath) {
        let state: String
        switch path.status {
        case .satisfied: state = "available"
        case .unsatisfied: state = "lost"
        case .requiresConnection: state = "requires_connection"
        @unknown default: state = "unknown"
        }

        var transports: [String] = []
        if path.usesInterfaceType(.wifi) { transports.append("wifi") }
        if path.usesInterfaceType(.cellular) { transports.append("cellular") }
        if path.usesInterfaceType(.wiredEthernet) { transports.append("ethernet") }
        if path.usesInterfaceType(.loopback) { transports.append("loopback") }
        if path.usesInterfaceType(.other) { transports.append("other") }

        // De-dupe identical back-to-back updates — NWPathMonitor emits liberally.
        let key = "\(state)|\(transports.joined(separator: ","))"
        lock.lock()
        let changed = (lastState != key)
        lastState = key
        lock.unlock()
        guard changed else { return }

        var props: [String: String] = ["state": state]
        if !transports.isEmpty {
            props["transport"] = transports.joined(separator: ",")
        }
        if path.isExpensive { props["expensive"] = "true" }
        if path.isConstrained { props["constrained"] = "true" }

        let runtime = self.runtime
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.connectivity,
                level: .info,
                props: props
            )
        }
    }
}
