import Foundation
import SwiftUI
import AppDiagLog

struct SettingsView: View {
    var body: some View {
        List {
            Section("SDK Status") {
                configRow(title: "SDK", value: SampleConfiguration.sdkVersionLabel)
                configRow(title: "Initialization", value: "Configured at app launch")
                configRow(title: "Debug logging", value: "Enabled")
                configRow(title: "MCP mode", value: SampleConfiguration.mcpModeDescription)
                configRow(title: "MCP server token", value: AppDiagLog.mcpServerToken ?? "Not running")
            }

            Section("Current Config") {
                configRow(title: "Max sessions", value: "\(SampleConfiguration.maxSessions)")
                configRow(title: "Max events / session", value: "\(SampleConfiguration.maxEventsPerSession)")
                configRow(title: "Disk budget", value: "\(SampleConfiguration.maxDiskUsageMB) MB")
                configRow(title: "Flush batch", value: "\(SampleConfiguration.flushBatchSize)")
                configRow(title: "Flush interval", value: "\(SampleConfiguration.flushIntervalMillis) ms")
                configRow(title: "Flush max wait", value: "\(SampleConfiguration.flushMaxWaitMillis) ms")
                configRow(title: "Session timeout", value: "\(SampleConfiguration.sessionTimeoutMinutes) min")
                configRow(title: "Rate limit", value: "\(SampleConfiguration.maxEventsPerSecond) events/sec")
                configRow(title: "Key wrap", value: SampleConfiguration.keyWrapDescription)
                configRow(title: "Symmetric", value: SampleConfiguration.symmetric.rawValue)
                configRow(title: "Auto-tracking", value: "All trackers enabled")
            }

            Section("Architecture Notes") {
                Text("UIKit owns tab selection, push navigation, and lifecycle callbacks in this sample. SwiftUI is used only for rendering screen content inside hosted controllers.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text("Session inspection, session tagging, and crash simulation are on the Session tab. Batch logging and the rate-limiter demo are on the Events Lab tab.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func configRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

