import UIKit
import SwiftUI
import AppDiagLog

final class AutoTrackingViewController: UIViewController {
    private lazy var hostingController = UIHostingController(
        rootView: AutoTrackingView { [weak self] in
            self?.pushDetailScreen()
        }
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Auto-Tracking"
        view.backgroundColor = .systemBackground
        embed(hostingController)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppDiagLog.setCurrentScreen("AutoTrackingScreen")
    }

    private func pushDetailScreen() {
        AppDiagLog.info("sample_push_detail", ["source": "AutoTrackingViewController", "navigation": "uikit"])
        navigationController?.pushViewController(AutoTrackingDetailHostingController(), animated: true)
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        child.didMove(toParent: self)
    }
}

private final class AutoTrackingDetailHostingController: UIViewController {
    private let hostingController = UIHostingController(rootView: AutoTrackingDetailView())

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Detail"
        view.backgroundColor = .systemBackground

        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }
}
