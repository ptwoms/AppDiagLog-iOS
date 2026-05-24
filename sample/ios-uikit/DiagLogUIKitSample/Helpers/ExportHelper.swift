import UIKit

enum ExportHelper {
    static func shareExport(zipURL: URL, presentingFrom sourceViewController: UIViewController? = nil) {
        let host = sourceViewController ?? topMostController()
        let activity = UIActivityViewController(activityItems: [zipURL], applicationActivities: nil)
        activity.excludedActivityTypes = [.assignToContact, .saveToCameraRoll, .openInIBooks]
        host?.present(activity, animated: true)
    }

    private static func topMostController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
