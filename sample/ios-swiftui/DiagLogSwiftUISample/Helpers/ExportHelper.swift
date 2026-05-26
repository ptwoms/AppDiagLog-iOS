import UIKit

enum ExportHelper {
    @MainActor
    static func shareExport(zipURL: URL) {
        let shareURL = stageForSharingIfNeeded(zipURL: zipURL)
        let host = topMostController()
        let activity = UIActivityViewController(activityItems: [shareURL], applicationActivities: nil)
        activity.excludedActivityTypes = [
            .assignToContact, .saveToCameraRoll, .openInIBooks,
            .print,
            .postToVimeo, .postToTencentWeibo, .postToWeibo, .postToTwitter, .postToFacebook, .postToFlickr
        ]
        activity.completionWithItemsHandler = { _, _, _, _ in
            cleanupStagedFileIfNeeded(shareURL: shareURL, originalURL: zipURL)
        }
        host?.present(activity, animated: true)
    }

    private static func stageForSharingIfNeeded(zipURL: URL) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        if zipURL.path.hasPrefix(tempDir.path) {
            return zipURL
        }

        let stagedURL = tempDir
            .appendingPathComponent("appdiaglog_share_\(UUID().uuidString)")
            .appendingPathExtension("zip")

        do {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                try FileManager.default.removeItem(at: stagedURL)
            }
            try FileManager.default.copyItem(at: zipURL, to: stagedURL)
            return stagedURL
        } catch {
            return zipURL
        }
    }

    private static func cleanupStagedFileIfNeeded(shareURL: URL, originalURL: URL) {
        guard shareURL != originalURL else { return }
        try? FileManager.default.removeItem(at: shareURL)
    }

    @MainActor
    private static func topMostController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        let keyWindow = windowScene?.windows.first { $0.isKeyWindow }
        var top = keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
