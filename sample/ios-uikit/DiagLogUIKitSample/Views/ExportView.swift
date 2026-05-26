import Foundation
import SwiftUI
import AppDiagLog

struct ExportView: View {
    @AppStorage(SampleConfiguration.DefaultsKey.enableMcpClient) private var mcpClientEnabled = false
    @ObservedObject private var mcpRuntime = SampleMcpRuntimeState.shared
    @State private var uploadURL = SampleConfiguration.uploadEndpoint
    @State private var bearerToken = SampleConfiguration.uploadBearerToken
    @State private var statusMessages = [LogEntry("Ready to export encrypted sessions.")]
    @State private var isWorking = false

    var body: some View {
        List {
            Section("Share") {
                Button {
                    Task {
                        await exportAndShare()
                    }
                } label: {
                    Label("Export & Share", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking)

                Button {
                    Task {
                        await exportViaMcp()
                    }
                } label: {
                    Label("Export via MCP", systemImage: "network.badge.shield.half.filled")
                }
                .disabled(isWorking || !mcpClientEnabled)

                if !mcpClientEnabled {
                    Text("Enable MCP client mode in Settings to use MCP export.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if mcpRuntime.clientAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter the MCP bearer token in Settings. The token is kept only until the app closes.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }

            Section("Upload") {
                TextField("Upload URL", text: $uploadURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Bearer token", text: $bearerToken)

                Button {
                    Task {
                        await exportAndUpload()
                    }
                } label: {
                    Label("Export & Upload", systemImage: "arrow.up.doc")
                }
                .disabled(isWorking)
            }

            Section("Status") {
                ForEach(statusMessages) {
                    Text($0.message)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @MainActor
    private func exportAndShare() async {
        isWorking = true
        appendStatus("Starting export for share sheet.")
        let result = await AppDiagLog.export()

        switch result {
        case .success(let file, let sessionCount, let totalBytes):
            appendStatus("Exported \(sessionCount) session(s), \(totalBytes) bytes. Presenting share sheet.")
            ExportHelper.shareExport(zipURL: file)
        case .failure(_, let message):
            appendStatus("Export failed: \(message)")
        }

        isWorking = false
    }

    @MainActor
    private func exportViaMcp() async {
        let token = mcpRuntime.clientAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            appendStatus("MCP export needs a bearer token. Enter it in Settings for this app session.")
            return
        }

        isWorking = true
        appendStatus("Starting MCP export.")
        let result = await AppDiagLog.exportViaMcp(
            config: .client(
                serverUrl: SampleConfiguration.sampleMcpClientURL,
                authToken: token,
                toolName: SampleConfiguration.sampleMcpClientToolName
            )
        )

        switch result {
        case .success(let sessionCount):
            appendStatus("MCP export succeeded with \(sessionCount) session(s).")
        case .failure(_, let message):
            appendStatus("MCP export failed: \(message)")
        }

        isWorking = false
    }

    @MainActor
    private func exportAndUpload() async {
        isWorking = true
        appendStatus("Starting export before upload.")
        let result = await AppDiagLog.export()

        switch result {
        case .success(let file, let sessionCount, let totalBytes):
            appendStatus("Exported \(sessionCount) session(s), \(totalBytes) bytes. Uploading archive.")
            do {
                let response = try await APIClient().upload(
                    fileURL: file,
                    to: uploadURL,
                    bearerToken: bearerToken
                )
                appendStatus("Upload result: \(response)")
            } catch {
                appendStatus("Upload failed: \(error.localizedDescription)")
            }
        case .failure(_, let message):
            appendStatus("Export failed: \(message)")
        }

        isWorking = false
    }

    private func appendStatus(_ message: String) {
        statusMessages.append(message)
    }
}
