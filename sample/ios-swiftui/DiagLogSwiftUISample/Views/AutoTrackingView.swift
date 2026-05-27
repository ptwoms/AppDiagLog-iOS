import SwiftUI
import AppDiagLog

struct AutoTrackingView: View {
    @State private var showDetail = false
    @State private var networkStatus = "Idle"
    @State private var actionLog = [LogEntry("Screen tracking starts when this tab appears.")]

    var body: some View {
        NavigationStack {
            List {
                Section("Navigation") {
                    Button {
                        showDetail = true
                        appendAction("Navigating to detail view.")
                    } label: {
                        Label("Navigate to Detail", systemImage: "arrow.right.circle")
                    }

                    Text("Both this screen and the destination use .trackScreen(_:) so screen views are logged automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }

                Section("Permissions") {
                    NavigationLink {
                        PermissionsView()
                    } label: {
                        Label("Permission Prompts", systemImage: "hand.raised.fill")
                    }
                    Text("Request Camera, Photo Library, Contacts, and Push Notification permissions. Each grant or denial triggers a permission_change event via PermissionChangeTracker.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("WebView") {
                    NavigationLink {
                        WebViewScreen()
                    } label: {
                        Label("Open WebView", systemImage: "globe")
                    }
                    Text("A real WKWebView that uses DiagLogNavigationDelegate. Every navigation event (start, finish, fail) is tracked automatically by WebViewTracker.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("System Auto-Tracking") {
                    Label("Connectivity changes are tracked automatically while the app runs.", systemImage: "wifi")
                        .font(.footnote)
                    Label("App lifecycle events (foreground/background) are logged automatically.", systemImage: "app.badge.checkmark")
                        .font(.footnote)
                    Label("Every tap on this screen is captured by the SDK's TapTracker.", systemImage: "hand.tap")
                        .font(.footnote)
                    Label("Use Xcode > Debug > Simulate Memory Warning to exercise memory-pressure tracking.", systemImage: "memorychip")
                        .font(.footnote)
                    Label("Battery level/state and thermal state changes are tracked automatically via BatteryTracker.", systemImage: "battery.75percent")
                        .font(.footnote)
                    Label("Open the app with a deep link to see .trackDeepLinks() in action.", systemImage: "link")
                        .font(.footnote)
                    Label("Crash simulation and session inspection are on the Session tab.", systemImage: "internaldrive")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Recent Actions") {
                    ForEach(actionLog) { action in
                        Text(action.message)
                            .font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle("Trackers")
            .navigationDestination(isPresented: $showDetail) {
                AutoTrackingDetailView()
            }
        }
        .trackScreen("AutoTrackingView")
        .trackDeepLinks()
    }

    private func makeNetworkRequest() async {
        networkStatus = "Requesting httpbin.org/get…"
        appendAction("Starting demo GET request.")

        guard let url = URL(string: "https://httpbin.org/get?source=appdiaglog-swiftui") else {
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
        actionLog.append(message)
    }
}

private struct AutoTrackingDetailView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Detail View")
                .font(.largeTitle.bold())

            Text("Push into this page to generate another screen-view event. Tap around, navigate back, or trigger export from another tab to inspect the session later.")
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
        .navigationTitle("Detail View")
        .trackScreen("DetailView")
    }
}
