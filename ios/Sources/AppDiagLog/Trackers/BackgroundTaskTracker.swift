import Foundation

/// Marker tracker that arms `BackgroundTaskTrackerBridge` when background-task
/// tracking is enabled. Apps report task lifecycle events via the public API
/// (`AppDiagLog.trackBackgroundTask`) from their BGTask handlers.
///
/// `BGTaskScheduler` expiration handlers are app-owned; there is no safe hook
/// for a library to intercept them. The bridge pattern keeps the SDK passive and
/// avoids requiring the BackgroundTasks entitlement.
final class BackgroundTaskTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        BackgroundTaskTrackerBridge.shared.arm(runtime: runtime)
    }

    func stop() async {
        BackgroundTaskTrackerBridge.shared.disarm()
    }
}

final class BackgroundTaskTrackerBridge: @unchecked Sendable {
    static let shared = BackgroundTaskTrackerBridge()

    private let lock = NSLock()
    private weak var runtime: AppDiagLogRuntime?
    private var armed = false

    private init() {}

    func arm(runtime: AppDiagLogRuntime) {
        lock.lock(); self.runtime = runtime; armed = true; lock.unlock()
    }

    func disarm() {
        lock.lock(); armed = false; runtime = nil; lock.unlock()
    }

    fileprivate func record(identifier: String, event: String) {
        lock.lock(); let runtime = self.runtime; let armed = self.armed; lock.unlock()
        guard armed, let runtime else { return }
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.backgroundTask,
                level: .info,
                props: ["identifier": identifier, "event": event]
            )
        }
    }
}

public extension AppDiagLog {
    /// Report a background task lifecycle event.
    ///
    /// Call with `event: "begin"` when your BGTask handler starts, `"expired"` from
    /// the `expirationHandler` closure, and `"completed"` before calling
    /// `BGTask.setTaskCompleted(success:)`.
    static func trackBackgroundTask(identifier: String, event: String) {
        BackgroundTaskTrackerBridge.shared.record(identifier: identifier, event: event)
    }
}
