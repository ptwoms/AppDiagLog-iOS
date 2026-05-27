import Foundation

/// Marker tracker that arms `PushNotificationTrackerBridge` when push-notification
/// tracking is enabled. Apps report delivery and interaction events via the public
/// API from their `UNUserNotificationCenterDelegate` callbacks.
///
/// Passive by design: the SDK cannot install itself as the UNUserNotificationCenter
/// delegate without risking conflict with the host app. The bridge pattern keeps
/// the SDK invisible and lets apps opt in per-notification.
final class PushNotificationTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        PushNotificationTrackerBridge.shared.arm(runtime: runtime)
    }

    func stop() async {
        PushNotificationTrackerBridge.shared.disarm()
    }
}

final class PushNotificationTrackerBridge: @unchecked Sendable {
    static let shared = PushNotificationTrackerBridge()

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

    fileprivate func recordReceived(categoryIdentifier: String) {
        emit(props: ["trigger": "received", "category": categoryIdentifier])
    }

    fileprivate func recordInteraction(actionIdentifier: String, categoryIdentifier: String) {
        emit(props: ["trigger": "action", "action_id": actionIdentifier, "category": categoryIdentifier])
    }

    private func emit(props: [String: String]) {
        lock.lock(); let runtime = self.runtime; let armed = self.armed; lock.unlock()
        guard armed, let runtime else { return }
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.push,
                level: .info,
                props: props
            )
        }
    }
}

public extension AppDiagLog {
    /// Report a push notification delivery event.
    ///
    /// Call from `UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:)`.
    /// Only the category identifier is recorded — the notification payload is never stored.
    static func trackPushReceived(categoryIdentifier: String = "") {
        PushNotificationTrackerBridge.shared.recordReceived(categoryIdentifier: categoryIdentifier)
    }

    /// Report a push notification interaction event.
    ///
    /// Call from `UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    /// Records which action the user took (e.g., default open, custom action ID) and the category.
    static func trackPushInteraction(actionIdentifier: String, categoryIdentifier: String = "") {
        PushNotificationTrackerBridge.shared.recordInteraction(
            actionIdentifier: actionIdentifier,
            categoryIdentifier: categoryIdentifier
        )
    }
}
