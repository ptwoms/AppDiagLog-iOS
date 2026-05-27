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

    fileprivate func currentScreenName() -> String? {
        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        lock.unlock()
        guard armed, let runtime else { return nil }
        return runtime.currentScreen.get()
    }

    fileprivate func observeViewDidAppear(
        _ viewController: UIViewController,
        screenBeforeViewDidAppear: String?
    ) {
        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        lock.unlock()
        guard armed, let runtime else { return }

        guard let screen = screenView(from: viewController, config: runtime.config.autoTrack.screenViews) else {
            return
        }

        let currentScreen = runtime.currentScreen.get()
        guard currentScreen == screenBeforeViewDidAppear else {
            // App code or SwiftUI `.trackScreen(_:)` already chose the meaningful name.
            return
        }
        guard currentScreen != screen.name else { return }

        runtime.currentScreen.set(screen.name)
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.screenView,
                level: .info,
                props: ["screen": screen.name, "kind": screen.kind]
            )
        }
    }

    private func screenView(
        from viewController: UIViewController,
        config: ScreenTrackingConfig?
    ) -> (name: String, kind: String)? {
        guard let config else { return nil }

        let controllerName = String(describing: type(of: viewController))
        guard !config.shouldSkipController(name: controllerName) else { return nil }

        let screenName: String
        let kind: String
        switch config.uikitNaming {
        case .className:
            screenName = controllerName
            kind = "automatic"
        case .accessibilityIdentifier:
            guard let id = viewController.view.accessibilityIdentifier, !id.isEmpty else {
                return nil
            }
            screenName = id
            kind = "accessibility_identifier"
        }

        guard config.shouldTrack(screenName: screenName) else { return nil }
        return (screenName, kind)
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
        let screenBeforeViewDidAppear = ScreenTrackerBridge.shared.currentScreenName()
        // After exchange this calls the *original* implementation.
        appdiaglog_viewDidAppear(animated)
        ScreenTrackerBridge.shared.observeViewDidAppear(
            self,
            screenBeforeViewDidAppear: screenBeforeViewDidAppear
        )
    }
}

#if canImport(SwiftUI)
public extension View {
    /// Records a SwiftUI `screen_view` using an explicit screen name.
    ///
    /// The name passes through the same `ScreenTrackingConfig` filters as UIKit
    /// controller names. Deduplicates: no event emitted if the name is unchanged.
    func trackScreen(_ name: String) -> some View {
        self.onAppear {
            AppDiagLog.trackScreen(name, kind: "swiftui")
        }
    }

    @available(*, deprecated, renamed: "trackScreen(_:)")
    func trackIdentifier(_ identifier: String) -> some View {
        trackScreen(identifier)
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
