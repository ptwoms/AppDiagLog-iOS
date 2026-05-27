import SwiftUI
import AppDiagLog
#if canImport(Darwin)
import Darwin
#endif

struct SessionView: View {
    @State private var sessionTag = "session-lab-repro"
    @State private var sessionInfo = SessionInspectInfo.read()
    @State private var pendingCrash: SampleCrashScenario?
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
                    Text("Each action terminates the app immediately. On the next launch the SDK records a crash event with source=previous_app_close and seals the prior session retroactively.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ForEach(SampleCrashScenario.allCases) { scenario in
                        Button(role: .destructive) {
                            pendingCrash = scenario
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scenario.title)
                                    Text(scenario.detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: scenario.icon)
                            }
                        }
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
                "Trigger crash?",
                isPresented: Binding(
                    get: { pendingCrash != nil },
                    set: { isPresented in
                        if !isPresented { pendingCrash = nil }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let pendingCrash {
                    Button(pendingCrash.title, role: .destructive) {
                        pendingCrash.trigger()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Relaunch the app after it terminates to let the SDK record the previous app close.")
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
        statusLog.append(message)
    }
}

private enum SampleCrashScenario: String, CaseIterable, Identifiable {
    case swiftFatalError
    case nsException
    case sigabrt
    case sigtrap
    case sigsegv
    case sigill
    case sigbus
    case sigfpe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .swiftFatalError: return "Swift fatalError"
        case .nsException: return "Objective-C NSException"
        case .sigabrt: return "Raise SIGABRT"
        case .sigtrap: return "Raise SIGTRAP"
        case .sigsegv: return "Raise SIGSEGV"
        case .sigill: return "Raise SIGILL"
        case .sigbus: return "Raise SIGBUS"
        case .sigfpe: return "Raise SIGFPE"
        }
    }

    var detail: String {
        switch self {
        case .swiftFatalError: return "Exercises Swift runtime trap handling."
        case .nsException: return "Exercises NSSetUncaughtExceptionHandler."
        case .sigabrt: return "Exercises abort-style signal capture."
        case .sigtrap: return "Exercises trap/breakpoint signal capture."
        case .sigsegv: return "Exercises segmentation fault signal capture."
        case .sigill: return "Exercises illegal instruction signal capture."
        case .sigbus: return "Exercises bus error signal capture."
        case .sigfpe: return "Exercises arithmetic exception signal capture."
        }
    }

    var icon: String {
        switch self {
        case .swiftFatalError: return "swift"
        case .nsException: return "exclamationmark.triangle"
        case .sigabrt: return "stop.circle"
        case .sigtrap: return "point.3.connected.trianglepath.dotted"
        case .sigsegv: return "bolt.trianglebadge.exclamationmark"
        case .sigill: return "xmark.octagon"
        case .sigbus: return "arrow.left.arrow.right.circle"
        case .sigfpe: return "divide.circle"
        }
    }

    func trigger() -> Never {
        switch self {
        case .swiftFatalError:
            fatalError("Sample crash — Swift fatalError from SwiftUI SessionView")
        case .nsException:
            NSException(
                name: .genericException,
                reason: "Sample crash — NSException from SwiftUI SessionView",
                userInfo: nil
            ).raise()
            fatalError("NSException.raise() unexpectedly returned")
        case .sigabrt:
            raiseSignal(SIGABRT)
        case .sigtrap:
            raiseSignal(SIGTRAP)
        case .sigsegv:
            raiseSignal(SIGSEGV)
        case .sigill:
            raiseSignal(SIGILL)
        case .sigbus:
            raiseSignal(SIGBUS)
        case .sigfpe:
            raiseSignal(SIGFPE)
        }
    }

    private func raiseSignal(_ signal: Int32) -> Never {
        #if canImport(Darwin)
        raise(signal)
        #endif
        fatalError("raise(\(signal)) unexpectedly returned")
    }
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
