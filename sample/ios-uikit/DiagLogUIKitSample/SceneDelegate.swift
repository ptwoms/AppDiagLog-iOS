import UIKit
import AppDiagLog

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MainTabBarController()
        self.window = window
        window.makeKeyAndVisible()

        if let url = connectionOptions.urlContexts.first?.url {
            logDeepLink(url, source: "launch")
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        logDeepLink(url, source: "scene_open_url")
    }

    private func logDeepLink(_ url: URL, source: String) {
        AppDiagLog.info(
            "sample_deep_link_opened",
            [
                "url": url.absoluteString,
                "source": source,
                "sample": "ios-uikit"
            ]
        )
    }
}
