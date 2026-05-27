import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Installs best-effort crash capture:
///
///   - `NSSetUncaughtExceptionHandler` — catches Objective-C NSException crashes
///   - POSIX signal handlers for SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGPIPE/SIGTRAP
///
/// Crash handlers write only a tiny marker file. On the next launch the SDK consumes
/// that marker and records a normal encrypted `crash` event in the new session. This
/// avoids actor hops, encryption, allocation-heavy stack capture, and file rewriting
/// while the process is already dying.
///
/// We do **not** override an existing crash reporter (Sentry/Crashlytics/etc.). Instead
/// we chain: on install we stash the previous handler and invoke it after our work.
final class CrashTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        CrashTrackerBridge.shared.install(runtime: runtime)
    }

    func stop() async {
        // We intentionally do NOT uninstall signal handlers or the exception hook —
        // those need to stay for the whole process lifetime. `stop()` is used by
        // tests/shutdown and simply disarms event emission.
        CrashTrackerBridge.shared.disarm()
    }
}

final class CrashTrackerBridge: @unchecked Sendable {
    static let shared = CrashTrackerBridge()

    private let lock = NSLock()
    private var installed = false
    private var armed = false
    private var markerPath: String?
    private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private var previousSignalHandlers: [Int32: sig_t] = [:]

    private static let capturedSignals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGPIPE, SIGTRAP]

    func install(runtime: AppDiagLogRuntime) {
        lock.lock(); defer { lock.unlock() }
        self.markerPath = runtime.crashMarkerStore.markerPath
        self.armed = true
        guard !installed else { return }
        installed = true

        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exc in
            CrashTrackerBridge.shared.handleException(exc)
        }

        for sig in Self.capturedSignals {
            let prior = signal(sig) { sig in
                CrashTrackerBridge.shared.handleSignal(sig)
            }
            if let prior {
                previousSignalHandlers[sig] = prior
            }
        }
    }

    func disarm() {
        lock.lock()
        armed = false
        markerPath = nil
        lock.unlock()
    }

    // MARK: - Handlers

    private func handleException(_ exc: NSException) {
        lock.lock()
        let armed = self.armed
        let markerPath = self.markerPath
        let previous = self.previousExceptionHandler
        lock.unlock()

        if armed, let markerPath {
            writeExceptionMarker(exc, to: markerPath)
        }

        previous?(exc)
    }

    private func handleSignal(_ sig: Int32) {
        lock.lock()
        let armed = self.armed
        let markerPath = self.markerPath
        let previous = previousSignalHandlers[sig]
        lock.unlock()

        if armed, let markerPath {
            CrashMarkerWriter.writeSignal(sig, to: markerPath)
        }

        // Reinstall default handler for this signal and re-raise so the OS generates
        // the proper crash report. Chaining to the prior handler would be incorrect
        // here because most crash reporters rely on getting the re-raised signal.
        signal(sig, previous ?? SIG_DFL)
        raise(sig)
    }

    private func writeExceptionMarker(_ exception: NSException, to path: String) {
        do {
            let data = try JSONEncoder().encode(CrashMarker.exception(exception))
            try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
        } catch {
            SdkLog.warn("failed to write crash marker", error: error)
        }
    }
}
