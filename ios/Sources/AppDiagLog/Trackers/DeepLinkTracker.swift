import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Deep-link capture. iOS deep-link delivery is fragmented (UIApplicationDelegate,
/// UIWindowSceneDelegate, SwiftUI `onOpenURL`, Universal Links via `NSUserActivity`),
/// and method swizzling across all of them is fragile. Instead we expose:
///
///   - `AppDiagLog.trackDeepLink(_:)` — public API the app calls manually
///   - `.trackDeepLinks()` — SwiftUI modifier that hooks `onOpenURL` automatically
///
/// The tracker itself is a marker — the registry records that the config opted in so
/// the two entry points above become no-ops when it's disabled.
final class DeepLinkTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        DeepLinkTrackerBridge.shared.arm(runtime: runtime)
    }

    func stop() async {
        DeepLinkTrackerBridge.shared.disarm()
    }
}

final class DeepLinkTrackerBridge: @unchecked Sendable {
    static let shared = DeepLinkTrackerBridge()

    private let lock = NSLock()
    private weak var runtime: AppDiagLogRuntime?
    private var armed = false

    func arm(runtime: AppDiagLogRuntime) {
        lock.lock()
        self.runtime = runtime
        self.armed = true
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        armed = false
        runtime = nil
        lock.unlock()
    }

    fileprivate func record(_ url: URL, source: String) {
        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        lock.unlock()
        guard armed, let runtime else { return }

        let props: [String: String] = [
            "uri": RedactionEngine.redactUrl(url.absoluteString),
            "scheme": url.scheme ?? "",
            "host": url.host ?? "",
            "source": source
        ]
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.deepLink,
                level: .info,
                props: props
            )
        }
    }
}

// MARK: - Public app-side hooks

public extension AppDiagLog {
    /// Call from your UIApplicationDelegate `application(_:open:options:)` or
    /// UIWindowSceneDelegate `scene(_:openURLContexts:)` implementation.
    static func trackDeepLink(_ url: URL, source: String = "manual") {
        DeepLinkTrackerBridge.shared.record(url, source: source)
    }
}

#if canImport(SwiftUI)
public extension View {
    /// SwiftUI convenience: wires `.onOpenURL` through the deep-link tracker. Apply
    /// this modifier to your root `WindowGroup` / root view.
    func trackDeepLinks() -> some View {
        self.onOpenURL { url in
            DeepLinkTrackerBridge.shared.record(url, source: "onOpenURL")
        }
    }
}
#endif
