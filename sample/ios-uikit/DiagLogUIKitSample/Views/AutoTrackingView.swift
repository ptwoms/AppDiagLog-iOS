import Foundation
import SwiftUI
import Network
import AppDiagLog
import Combine

struct AutoTrackingView: View {
    let onPushDetail: () -> Void

    @StateObject private var connectivityObserver = ConnectivityObserver()
    @State private var networkStatus = "Idle"
    @State private var actionLog = ["UIKit screen tracking starts when this tab appears."]

    var body: some View {
        List {
            Section("Navigation") {
                Button {
                    appendAction("Requesting UIKit push to detail screen.")
                    onPushDetail()
                } label: {
                    Label("Push Detail", systemImage: "arrow.right.circle")
                }

                Text("UIKit owns the navigation stack for this tab. The SwiftUI content simply asks the controller to push another screen.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Network") {
                Button {
                    Task {
                        await makeNetworkRequest()
                    }
                } label: {
                    Label("Make Network Request", systemImage: "network")
                }

                Text(networkStatus)
                    .font(.footnote.monospaced())
                    .foregroundColor(.secondary)
            }

            Section("Connectivity") {
                Label(connectivityObserver.statusText, systemImage: connectivityObserver.iconName)
                    .font(.footnote)
                Text("Connectivity changes are auto-tracked by the SDK while this demo also shows the current state from NWPathMonitor.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("System Auto-Tracking") {
                Label("Tap around the tab bar and push/pop this detail flow to generate UIKit lifecycle events.", systemImage: "rectangle.stack")
                    .font(.footnote)
                Label("App lifecycle events (foreground/background) are logged automatically.", systemImage: "app.badge.checkmark")
                    .font(.footnote)
                Label("Every tap is captured by the SDK's TapTracker.", systemImage: "hand.tap")
                    .font(.footnote)
                Label("Use Xcode > Debug > Simulate Memory Warning to exercise memory-pressure tracking.", systemImage: "memorychip")
                    .font(.footnote)
                Label("Open a diagloguikit:// URL to exercise deep-link logging from SceneDelegate.", systemImage: "link")
                    .font(.footnote)
                Label("Crash simulation and session inspection are on the Session tab.", systemImage: "internaldrive")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Recent Actions") {
                ForEach(Array(actionLog.enumerated()), id: \.offset) { _, action in
                    Text(action)
                        .font(.footnote.monospaced())
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func makeNetworkRequest() async {
        networkStatus = "Requesting httpbin.org/get…"
        appendAction("Starting demo GET request.")

        guard let url = URL(string: "https://httpbin.org/get?source=appdiaglog-uikit") else {
            networkStatus = "Invalid request URL."
            appendAction("Request aborted because the URL was invalid.")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let preview = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            networkStatus = "HTTP \(statusCode): \(preview)"
            appendAction("Finished demo GET request with HTTP \(statusCode).")
        } catch {
            networkStatus = "Request failed: \(error.localizedDescription)"
            appendAction("Demo GET request failed: \(error.localizedDescription)")
        }
    }

    private func appendAction(_ message: String) {
        actionLog.insert("\(timestamp())  \(message)", at: 0)
        actionLog = Array(actionLog.prefix(12))
    }

    private func timestamp() -> String {
        Date().formatted(date: .omitted, time: .standard)
    }
}

private final class ConnectivityObserver: ObservableObject {
    @Published private(set) var statusText = "Checking connection…"
    @Published private(set) var iconName = "wifi"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sample.ios-uikit.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                if path.status == .satisfied {
                    if path.usesInterfaceType(.wifi) {
                        self.statusText = "Connected via Wi-Fi"
                        self.iconName = "wifi"
                    } else if path.usesInterfaceType(.cellular) {
                        self.statusText = "Connected via Cellular"
                        self.iconName = "antenna.radiowaves.left.and.right"
                    } else if path.usesInterfaceType(.wiredEthernet) {
                        self.statusText = "Connected via Ethernet"
                        self.iconName = "cable.connector"
                    } else {
                        self.statusText = "Connected"
                        self.iconName = "network"
                    }
                } else {
                    self.statusText = "Offline"
                    self.iconName = "wifi.slash"
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
