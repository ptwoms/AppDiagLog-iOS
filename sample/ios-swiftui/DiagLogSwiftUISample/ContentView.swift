import SwiftUI
import AppDiagLog

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LoggingView()
                .tabItem {
                    Label("Logging", systemImage: "pencil.and.list.clipboard")
                }
                .tag(0)

            EventsLabView()
                .tabItem {
                    Label("Events Lab", systemImage: "bolt.fill")
                }
                .tag(1)

            AutoTrackingView()
                .tabItem {
                    Label("Trackers", systemImage: "waveform.path.ecg")
                }
                .tag(2)

            TrackerProbesView()
                .tabItem {
                    Label("Probes", systemImage: "scope")
                }
                .tag(3)

            ExportView()
                .tabItem {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .tag(4)

            SessionView()
                .tabItem {
                    Label("Session", systemImage: "internaldrive")
                }
                .tag(5)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(6)
        }
        .trackScreen("ContentView")
    }
}
