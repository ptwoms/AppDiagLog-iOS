import UIKit

final class MainTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        tabBar.tintColor = .systemBlue
        setViewControllers(makeTabs(), animated: false)
    }

    private func makeTabs() -> [UIViewController] {
        [
            navigationController(
                root: LoggingViewController(),
                title: "Logging",
                imageName: "pencil.and.list.clipboard"
            ),
            navigationController(
                root: EventsLabViewController(),
                title: "Events Lab",
                imageName: "bolt.fill"
            ),
            navigationController(
                root: AutoTrackingViewController(),
                title: "Trackers",
                imageName: "waveform.path.ecg"
            ),
            navigationController(
                root: TrackerProbesViewController(),
                title: "Probes",
                imageName: "scope"
            ),
            navigationController(
                root: ExportViewController(),
                title: "Export",
                imageName: "square.and.arrow.up"
            ),
            navigationController(
                root: SessionViewController(),
                title: "Session",
                imageName: "internaldrive"
            ),
            navigationController(
                root: SettingsViewController(),
                title: "Settings",
                imageName: "gearshape"
            )
        ]
    }

    private func navigationController(
        root: UIViewController,
        title: String,
        imageName: String
    ) -> UINavigationController {
        root.title = title
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.navigationBar.prefersLargeTitles = true
        navigationController.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: imageName), selectedImage: nil)
        return navigationController
    }
}
