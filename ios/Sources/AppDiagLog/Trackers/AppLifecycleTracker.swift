import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Observes process foreground/background transitions to:
///   1. emit `app_foreground` / `app_background` events
///   2. flush the pipeline when we go to background (spec: flush-on-background)
///   3. drive SessionManager.maybeResumeOrRotate on foreground (idle-timeout rotation)
final class AppLifecycleTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        // Use .main because UIApplication posts on the main thread and observers must
        // run before any UIKit state-dependent work. We then hop to a detached Task.
        let fgToken = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleForeground()
        }
        let bgToken = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleBackground()
        }
        setTokens([fgToken, bgToken])
        #endif
    }

    func stop() async {
        let drained = drainTokens()
        for token in drained {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Sync lock helpers
    //
    // Swift 6 forbids calling `NSLock.lock()` from async contexts because the compiler
    // can't guarantee the critical section doesn't straddle a suspension point. We keep
    // all lock access inside these non-async helpers so the async methods above stay
    // strict-concurrency-clean.

    private func setTokens(_ newTokens: [NSObjectProtocol]) {
        lock.lock(); defer { lock.unlock() }
        tokens = newTokens
    }

    private func drainTokens() -> [NSObjectProtocol] {
        lock.lock(); defer { lock.unlock() }
        let t = tokens
        tokens.removeAll()
        return t
    }

    // MARK: - Handlers

    private func handleForeground() {
        let runtime = self.runtime
        Task.detached(priority: .utility) {
            SdkLog.debug("app will enter foreground")
            await runtime.pipeline.enqueue(
                event: EventName.appForeground,
                level: .info,
                props: [:]
            )
            let prior = await runtime.sessionManager.ensureSession()?.id
            if let outcome = await runtime.sessionManager.maybeResumeOrRotate() {
                if outcome.1 || outcome.0.id != prior {
                    await runtime.pipeline.handleSessionRotated()
                }
            }
        }
    }

    private func handleBackground() {
        let runtime = self.runtime
        Task.detached(priority: .utility) {
            SdkLog.debug("app did enter background")
            await runtime.pipeline.enqueue(
                event: EventName.appBackground,
                level: .info,
                props: [:]
            )
            // Flush first so any in-flight events are persisted, then mark the session
            // as backgrounded (no re-flush; pipeline.flushOnce already wrote them).
            await runtime.pipeline.flushOnce()
            await runtime.sessionManager.markBackgrounded(with: [])
        }
    }
}
