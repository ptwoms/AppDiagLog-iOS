#if canImport(UIKit) && (os(iOS) || os(tvOS))
import UIKit
import ObjectiveC.runtime
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Logs UIKit screen views by swizzling `UIViewController.viewDidAppear(_:)`.
///
/// SwiftUI-only apps should additionally use the `.trackScreen(_:)` modifier below,
/// because SwiftUI bodies don't map 1:1 to UIViewControllers.
///
/// The swizzle is installed exactly once, process-wide. `stop()` flips a shared gate —
/// we never uninstall the method swap, because Objective-C runtime swizzling is
/// notoriously risky to reverse when multiple SDKs touch the same selector.
final class ScreenTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        ScreenTrackerBridge.shared.install(runtime: runtime)
    }

    func stop() async {
        ScreenTrackerBridge.shared.disarm()
    }
}

/// Process-singleton bridge for the ObjC swizzle. Lives outside the Tracker type so the
/// swizzled selector can look it up regardless of tracker lifetime.
final class ScreenTrackerBridge: @unchecked Sendable {
    static let shared = ScreenTrackerBridge()

    private let lock = NSLock()
    private var installed = false
    private var armed = false
    private weak var runtime: AppDiagLogRuntime?

    func install(runtime: AppDiagLogRuntime) {
        lock.lock()
        defer { lock.unlock() }
        self.runtime = runtime
        self.armed = true
        guard !installed else { return }
        installed = true
        Self.swizzleViewDidAppear()
    }

    func disarm() {
        lock.lock()
        armed = false
        runtime = nil
        lock.unlock()
    }

    fileprivate func observeViewDidAppear(_ viewController: UIViewController) {
        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        lock.unlock()
        guard armed, let runtime else { return }

        let name = String(describing: type(of: viewController))
        // Skip obvious UIKit containers that aren't real screens. Heuristic only.
        if Self.shouldSkip(name: name) { return }

        runtime.currentScreen.set(name)
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.screenView,
                level: .info,
                props: ["screen": name, "kind": "uikit"]
            )
        }
    }

    private static func shouldSkip(name: String) -> Bool {
        // Common container / private classes.
        let skipped = [
            "UINavigationController", "UITabBarController", "UISplitViewController",
            "UIPageViewController", "UIAlertController", "UIInputViewController",
            "UICompatibilityInputViewController", "_UIRemoteKeyboardViewController",
            "UISystemInputAssistantViewController"
        ]
        if skipped.contains(name) { return true }
        if name.hasPrefix("_") || name.hasPrefix("SwiftUI.") { return true }
        return false
    }

    private static func swizzleViewDidAppear() {
        let cls: AnyClass = UIViewController.self
        let original = #selector(UIViewController.viewDidAppear(_:))
        let swizzled = #selector(UIViewController.appdiaglog_viewDidAppear(_:))
        guard
            let o = class_getInstanceMethod(cls, original),
            let s = class_getInstanceMethod(cls, swizzled)
        else { return }
        method_exchangeImplementations(o, s)
    }
}

extension UIViewController {
    @objc fileprivate func appdiaglog_viewDidAppear(_ animated: Bool) {
        // After exchange this calls the *original* implementation.
        appdiaglog_viewDidAppear(animated)
        ScreenTrackerBridge.shared.observeViewDidAppear(self)
    }
}

#if canImport(SwiftUI)
public extension View {
    /// Records a `screen_view` event when this view appears. Deduplicates: no event emitted
    /// if the screen name is unchanged (prevents duplicate logs from SwiftUI redraws that
    /// re-fire `onAppear` without actual navigation). Preferred for pure-SwiftUI apps
    /// because SwiftUI bodies don't correspond 1:1 to UIViewControllers.
    func trackScreen(_ name: String) -> some View {
        self.onAppear {
            AppDiagLog.trackScreen(name)
        }
    }
}
#endif
#else
// Non-UIKit platforms get a no-op tracker so AutoTrackRegistry still compiles.
final class ScreenTracker: Tracker, @unchecked Sendable {
    init(runtime: AppDiagLogRuntime) {}
    func start() async {}
    func stop() async {}
}
#endif
