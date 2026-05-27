import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Observes `UIApplication.didReceiveMemoryWarningNotification` and emits a
/// `memory_warning` event. Decoupled from AppLifecycleTracker so the
/// `memoryPressure` config flag controls it independently.
final class MemoryPressureTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        let t = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleWarning()
        }
        setToken(t)
    }

    func stop() async {
        if let t = takeToken() {
            NotificationCenter.default.removeObserver(t)
        }
    }

    // MARK: - Sync lock helpers

    private func setToken(_ t: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        token = t
    }

    private func takeToken() -> NSObjectProtocol? {
        lock.lock(); defer { lock.unlock() }
        let t = token; token = nil; return t
    }

    // MARK: - Handler

    private func handleWarning() {
        let runtime = self.runtime
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.memoryWarning,
                level: .warning,
                props: [:]
            )
        }
    }
}
#endif
