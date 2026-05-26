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
        NavigationStack {
            List {
                Section("SDK Status") {
                    LabeledContent("SDK") { Text(SampleConfiguration.sdkVersionLabel) }
                    LabeledContent("Initialization") { Text("Configured at app launch") }
                    LabeledContent("Debug logging") { Text("Enabled") }
                    LabeledContent("Saved MCP mode") { Text(SampleConfiguration.mcpModeDescription) }
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
                            .foregroundStyle(.secondary)
                        Text("The bundled backend listens on plain HTTP at localhost:8080 unless you configure TLS.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
                        Text("Leave the token blank to generate one. The effective token appears after Start.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let serverStatus = mcpRuntime.serverStatus {
                            Text(serverStatus)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
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
