import Foundation
import SwiftUI
import AppDiagLog

struct SettingsView: View {
    @AppStorage(SampleConfiguration.DefaultsKey.enableMcpClient) private var mcpClientEnabled = false
    @AppStorage(SampleConfiguration.DefaultsKey.enableMcpServer) private var mcpServerEnabled = false
    @AppStorage(SampleConfiguration.DefaultsKey.mcpClientURL) private var mcpClientURL = SampleConfiguration.defaultMcpClientURL
    @AppStorage(SampleConfiguration.DefaultsKey.mcpClientToolName) private var mcpClientToolName = SampleConfiguration.defaultMcpClientToolName
    @AppStorage(SampleConfiguration.DefaultsKey.mcpServerPort) private var mcpServerPort = SampleConfiguration.defaultMcpServerPort
    @AppStorage(SampleConfiguration.DefaultsKey.mcpServerBindAddress) private var mcpServerBindAddress = SampleConfiguration.defaultMcpServerBindAddress
    @ObservedObject private var mcpRuntime = SampleMcpRuntimeState.shared

    var body: some View {
        List {
            Section("SDK Status") {
                configRow(title: "SDK", value: SampleConfiguration.sdkVersionLabel)
                configRow(title: "Initialization", value: "Configured at app launch")
                configRow(title: "Debug logging", value: "Enabled")
                configRow(title: "Saved MCP mode", value: SampleConfiguration.mcpModeDescription)
            }

            Section("MCP Client") {
                Toggle("Enable client mode", isOn: $mcpClientEnabled)
                if mcpClientEnabled {
                    TextField("Server URL", text: $mcpClientURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token", text: $mcpRuntime.clientAuthToken)
                    TextField("Tool name", text: $mcpClientToolName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Client mode submits encrypted exports to a remote MCP endpoint. The bearer token is kept in memory only and clears on relaunch.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("The bundled backend listens on plain HTTP at localhost:8080 unless you configure TLS.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: mcpClientEnabled) { enabled in
                if enabled { mcpServerEnabled = false }
            }

            Section("MCP Server") {
                Toggle("Enable server mode", isOn: $mcpServerEnabled)
                if mcpServerEnabled {
                    TextField("Port", value: $mcpServerPort, format: .number)
                        .keyboardType(.numberPad)
                    TextField("Bind address", text: $mcpServerBindAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token (optional)", text: serverAuthTokenBinding)
                    Button {
                        if mcpRuntime.isServerRunning {
                            stopMcpServer()
                        } else {
                            startMcpServer()
                        }
                    } label: {
                        Label(
                            mcpRuntime.isServerRunning ? "Stop MCP Server" : "Start MCP Server",
                            systemImage: mcpRuntime.isServerRunning ? "stop.circle" : "play.circle"
                        )
                    }
                    Text("Server mode exposes encrypted session tools from this device. Start applies the current settings immediately.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text("Leave the token blank to generate one. The effective token appears after Start.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if let serverStatus = mcpRuntime.serverStatus {
                        Text(serverStatus)
                            .font(.footnote.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .onChange(of: mcpServerEnabled) { enabled in
                if enabled {
                    mcpClientEnabled = false
                } else if mcpRuntime.isServerRunning {
                    stopMcpServer()
                }
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

    private var serverAuthTokenBinding: Binding<String> {
        Binding(
            get: { mcpRuntime.serverAuthToken ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                mcpRuntime.serverAuthToken = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func startMcpServer() {
        Task {
            let token = await AppDiagLog.startMcpServer(
                config: .server(
                    port: UInt16(max(1, min(mcpServerPort, Int(UInt16.max)))),
                    authToken: mcpRuntime.serverAuthToken,
                    allowedOrigins: ["*"],
                    bindAddress: mcpServerBindAddress
                )
            )
            await MainActor.run {
                mcpRuntime.isServerRunning = true
                mcpRuntime.serverStatus = "MCP server started. Token: \(token ?? "Not available")"
            }
        }
    }

    private func stopMcpServer() {
        AppDiagLog.stopMcpServer()
        mcpRuntime.isServerRunning = false
        mcpRuntime.serverStatus = "MCP server stopped."
    }
}
