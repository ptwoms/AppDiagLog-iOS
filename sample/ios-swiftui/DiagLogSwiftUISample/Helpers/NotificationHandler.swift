import Foundation
import UserNotifications
import AppDiagLog

final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationHandler()

    private override init() {}

    func setup() {
        UNUserNotificationCenter.current().delegate = self

        let viewAction = UNNotificationAction(
            identifier: "view_order",
            title: "View Order",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: "dismiss_order",
            title: "Dismiss",
            options: .destructive
        )
        let orderCategory = UNNotificationCategory(
            identifier: "order_update",
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([orderCategory])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AppDiagLog.trackPushReceived(
            categoryIdentifier: notification.request.content.categoryIdentifier
        )
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        AppDiagLog.trackPushInteraction(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier
        )
        completionHandler()
    }
}
