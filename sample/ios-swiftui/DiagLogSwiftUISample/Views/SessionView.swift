import SwiftUI
import AppDiagLog

struct SessionView: View {
    @State private var sessionTag = "session-lab-repro"
    @State private var sessionInfo = SessionInspectInfo.read()
    @State private var showCrashConfirmation = false
    @State private var statusLog = [LogEntry("Session lab ready.")]

    var body: some View {
        NavigationStack {
            List {
                Section("Session Controls") {
                    Text("Tag the active session so the backend can correlate it with a user-reported issue.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Session tag", text: $sessionTag)
                        .autocorrectionDisabled()

                    Button {
                        let trimmed = sessionTag.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        AppDiagLog.tagSession(trimmed)
                        appendStatus("Tagged session as \(trimmed).")
                    } label: {
                        Label("Tag Current Session", systemImage: "tag")
                    }
                    .disabled(sessionTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        AppDiagLog.warning("manual_seal_requested", ["source": "SessionView"])
                        AppDiagLog.tagSession("force-sealed-from-session-lab")
                        AppDiagLog.shutdown()
                        sessionInfo = SessionInspectInfo.read()
                        appendStatus("Sealed session and shut down SDK. Relaunch the app to start a fresh session.")
                    } label: {
                        Label("Force Seal & Shutdown SDK", systemImage: "lock.shield")
                    }
                }

                Section("Session Inspection") {
                    Text("Reads the session index directly from app-private storage (applicationSupportDirectory/appdiaglog).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    infoRow("Session files", "\(sessionInfo.fileCount)")
                    infoRow("In index", "\(sessionInfo.sessionCount)")
                    infoRow("Sealed", "\(sessionInfo.sealedCount)")
                    infoRow("Open", "\(sessionInfo.openCount)")
                    infoRow("Total bytes", formatBytes(sessionInfo.totalBytes))
                    infoRow("Latest session ID", sessionInfo.latestId)
                    infoRow("Latest tag", sessionInfo.latestTag)

                    Button {
                        sessionInfo = SessionInspectInfo.read()
                        appendStatus("Refreshed session status.")
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                }

                Section("Crash Simulation") {
                    Text("Throws a fatal error to exercise the crash tracker. The app terminates immediately. On the next launch the SDK seals the crashed session retroactively — worst-case data loss is one flush buffer (≤50 events / 5 s).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(role: .destructive) {
                        showCrashConfirmation = true
                    } label: {
                        Label("Simulate Crash (app will die)", systemImage: "exclamationmark.octagon")
                    }
                }

                Section("Status") {
                    ForEach(statusLog) { message in
                        Text(message.message)
                            .font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle("Session")
            .confirmationDialog(
                "Simulate crash?",
                isPresented: $showCrashConfirmation,
                titleVisibility: .visible
            ) {
                Button("Crash Now", role: .destructive) {
                    fatalError("Sample crash — triggered from SessionView")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The app will terminate immediately. The crash tracker seals the session automatically.")
            }
        }
        .trackScreen("SessionView")
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        bytes >= 1024 ? "\(bytes / 1024) KB (\(bytes) B)" : "\(bytes) B"
    }

    private func appendStatus(_ message: String) {
        statusLog.insert(LogEntry("\(timestamp())  \(message)"), at: 0)
        statusLog = Array(statusLog.prefix(12))
    }

    private func timestamp() -> String {
        Date.now.formatted(date: .omitted, time: .standard)
    }
}

// MARK: - Shared log entry

private struct LogEntry: Identifiable {
    let id = UUID()
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Session index reader

private struct SessionInspectInfo {
    let fileCount: Int
    let sessionCount: Int
    let sealedCount: Int
    let openCount: Int
    let totalBytes: Int64
    let latestId: String
    let latestTag: String

    static func read() -> SessionInspectInfo {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return empty()
        }
        let root = support.appendingPathComponent("appdiaglog")
        let sessionsDir = root.appendingPathComponent("sessions")
        let indexURL = root.appendingPathComponent("session_index.json")

        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let totalBytes = files.compactMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        }.reduce(0, +)

        guard let data = try? Data(contentsOf: indexURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["sessions"] as? [[String: Any]] else {
            return SessionInspectInfo(
                fileCount: files.count, sessionCount: 0,
                sealedCount: 0, openCount: 0,
                totalBytes: Int64(totalBytes),
                latestId: "none", latestTag: "none"
            )
        }

        var sealedCount = 0
        var openCount = 0
        var latestId = "none"
        var latestTag = "none"

        for session in sessions {
            if session["sealed"] as? Bool == true {
                sealedCount += 1
            } else {
                openCount += 1
            }
            if let id = session["id"] as? String { latestId = id }
            if let tag = session["session_tag"] as? String, !tag.isEmpty { latestTag = tag }
        }

        return SessionInspectInfo(
            fileCount: files.count,
            sessionCount: sessions.count,
            sealedCount: sealedCount,
            openCount: openCount,
            totalBytes: Int64(totalBytes),
            latestId: latestId,
            latestTag: latestTag
        )
    }

    private static func empty() -> SessionInspectInfo {
        SessionInspectInfo(
            fileCount: 0, sessionCount: 0,
            sealedCount: 0, openCount: 0,
            totalBytes: 0,
            latestId: "none", latestTag: "none"
        )
    }
}
