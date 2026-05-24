import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Installs best-effort crash capture:
///
///   - `NSSetUncaughtExceptionHandler` — catches Objective-C NSException crashes
///   - POSIX signal handlers for SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGPIPE
///
/// When a crash fires we have ~200-1000ms before the process dies, so we record the
/// crash event and then bridge synchronously into our structured-concurrency pipeline
/// using a `DispatchSemaphore`. This is the SDK's only other pragmatic GCD touchpoint
/// — it's the only reliable way to block a signal handler until a `Task { await ... }`
/// completes.
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
    private weak var runtime: AppDiagLogRuntime?
    private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?
    private var previousSignalHandlers: [Int32: sig_t] = [:]

    private static let capturedSignals: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGBUS, SIGFPE, SIGPIPE]

    func install(runtime: AppDiagLogRuntime) {
        lock.lock(); defer { lock.unlock() }
        self.runtime = runtime
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
        runtime = nil
        lock.unlock()
    }

    // MARK: - Handlers

    private func handleException(_ exc: NSException) {
        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        let previous = self.previousExceptionHandler
        lock.unlock()

        if armed, let runtime {
            let stack = exc.callStackSymbols.prefix(64).joined(separator: "\n")
            let props: [String: String] = [
                "type": "NSException:\(exc.name.rawValue)",
                "reason": exc.reason ?? "",
                "stack": truncate(stack)
            ]
            record(runtime: runtime, props: props)
        }

        previous?(exc)
    }

    private func handleSignal(_ sig: Int32) {
        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        let previous = previousSignalHandlers[sig]
        lock.unlock()

        if armed, let runtime {
            let name = Self.signalName(sig)
            let stack = Thread.callStackSymbols.prefix(64).joined(separator: "\n")
            let props: [String: String] = [
                "type": "Signal:\(name)",
                "reason": "signal \(sig)",
                "stack": truncate(stack)
            ]
            record(runtime: runtime, props: props)
        }

        // Reinstall default handler for this signal and re-raise so the OS generates
        // the proper crash report. Chaining to the prior handler would be incorrect
        // here because most crash reporters rely on getting the re-raised signal.
        signal(sig, previous ?? SIG_DFL)
        raise(sig)
    }

    // MARK: - Bridge to async pipeline

    /// Crash handlers cannot `await`. We use a DispatchSemaphore to block until the
    /// detached task signals back — the process is dying anyway, so a short block on
    /// whichever thread triggered the crash is acceptable.
    private func record(runtime: AppDiagLogRuntime, props: [String: String]) {
        let sema = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await runtime.pipeline.enqueue(
                event: EventName.crash,
                level: .error,
                props: props
            )
            // Final shutdown: flush remaining events + seal the session file.
            await runtime.pipeline.shutdown()
            sema.signal()
        }
        // 1s budget
        _ = sema.wait(timeout: .now() + .seconds(1))
    }

    private func truncate(_ s: String) -> String {
        if s.count <= 4000 { return s }
        return String(s.prefix(4000)) + "…(truncated)"
    }

    private static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGILL:  return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGFPE:  return "SIGFPE"
        case SIGPIPE: return "SIGPIPE"
        default:      return "SIG\(sig)"
        }
    }
}
