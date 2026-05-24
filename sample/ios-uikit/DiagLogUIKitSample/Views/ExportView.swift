import Foundation
import SwiftUI
import AppDiagLog

struct ExportView: View {
    @State private var uploadURL = SampleConfiguration.uploadEndpoint
    @State private var bearerToken = SampleConfiguration.uploadBearerToken
    @State private var statusMessages = ["Ready to export encrypted sessions."]
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
                .disabled(isWorking || !SampleConfiguration.enableMcpClient)

                if !SampleConfiguration.enableMcpClient {
                    Text("Enable SampleConfiguration.enableMcpClient to demo MCP export from this screen.")
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
                ForEach(Array(statusMessages.enumerated()), id: \.offset) { _, message in
                    Text(message)
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
        isWorking = true
        appendStatus("Starting MCP export.")
        let result = await AppDiagLog.exportViaMcp()

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
        statusMessages.insert("\(timestamp())  \(message)", at: 0)
        statusMessages = Array(statusMessages.prefix(20))
    }

    private func timestamp() -> String {
        Date().formatted(date: .omitted, time: .standard)
    }
}
