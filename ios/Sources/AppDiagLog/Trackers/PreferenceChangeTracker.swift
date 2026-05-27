import Foundation

/// Observes `UserDefaults.didChangeNotification` and emits a `preference_change` event.
///
/// The notification fires once per logical change but may burst during bulk writes.
/// A 1-second debounce coalesces bursts into a single event. No key or value is
/// recorded — only the fact that preferences changed — to avoid PII exposure.
///
/// Refer to Apple documentation for details on `UserDefaults.didChangeNotification` behavior and limitations:
/// - https://developer.apple.com/documentation/foundation/userdefaults/didchangenotification
final class PreferenceChangeTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        let t = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleEmit()
        }
        setToken(t)
    }

    func stop() async {
        let (t, pending) = drainState()
        if let t { NotificationCenter.default.removeObserver(t) }
        pending?.cancel()
    }

    // MARK: - Sync lock helpers

    private func setToken(_ t: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        token = t
    }

    private func drainState() -> (NSObjectProtocol?, Task<Void, Never>?) {
        lock.lock(); defer { lock.unlock() }
        let t = token; token = nil
        let pending = debounceTask; debounceTask = nil
        return (t, pending)
    }

    private func swapDebounceTask(_ newTask: Task<Void, Never>) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        let old = debounceTask; debounceTask = newTask; return old
    }

    // MARK: - Debounce
    private func scheduleEmit() {
        let runtime = self.runtime
        let newTask = Task.detached(priority: .utility) {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            await runtime.pipeline.enqueue(
                event: EventName.preferenceChange,
                level: .info,
                props: [:]
            )
        }
        swapDebounceTask(newTask)?.cancel()
    }
}
