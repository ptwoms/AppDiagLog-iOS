import UIKit
import SwiftUI
import AppDiagLog

final class ExportViewController: UIViewController {
    private let hostingController = UIHostingController(rootView: ExportView())

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Export"
        view.backgroundColor = .systemBackground
        embed(hostingController)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppDiagLog.setCurrentScreen("ExportScreen")
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
