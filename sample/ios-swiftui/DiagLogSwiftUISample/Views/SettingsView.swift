import SwiftUI
import AppDiagLog

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("SDK Status") {
                    LabeledContent("SDK") { Text(SampleConfiguration.sdkVersionLabel) }
                    LabeledContent("Initialization") { Text("Configured at app launch") }
                    LabeledContent("Debug logging") { Text("Enabled") }
                    LabeledContent("MCP mode") { Text(SampleConfiguration.mcpModeDescription) }
                    LabeledContent("MCP server token") { Text(AppDiagLog.mcpServerToken ?? "Not running") }
                }

                Section("Current Config") {
                    LabeledContent("Max sessions") { Text("\(SampleConfiguration.maxSessions)") }
                    LabeledContent("Max events / session") { Text("\(SampleConfiguration.maxEventsPerSession)") }
                    LabeledContent("Disk budget") { Text("\(SampleConfiguration.maxDiskUsageMB) MB") }
                    LabeledContent("Flush batch") { Text("\(SampleConfiguration.flushBatchSize)") }
                    LabeledContent("Flush interval") { Text("\(SampleConfiguration.flushIntervalMillis) ms") }
                    LabeledContent("Flush max wait") { Text("\(SampleConfiguration.flushMaxWaitMillis) ms") }
                    LabeledContent("Session timeout") { Text("\(SampleConfiguration.sessionTimeoutMinutes) min") }
                    LabeledContent("Rate limit") { Text("\(SampleConfiguration.maxEventsPerSecond) events/sec") }
                    LabeledContent("Key wrap") { Text("RSA-OAEP-3072 placeholder") }
                    LabeledContent("Symmetric") { Text("AES-256-GCM") }
                    LabeledContent("Auto-tracking") { Text("All trackers enabled") }
                }

                Section("Notes") {
                    Text("Session inspection, session tagging, and crash simulation are on the Session tab. Batch logging and the rate-limiter demo are on the Events Lab tab.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
        .trackScreen("SettingsView")
    }
}
