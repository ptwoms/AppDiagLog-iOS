#if canImport(UIKit) && (os(iOS) || os(tvOS))
import UIKit
import ObjectiveC.runtime

/// Observes taps by swizzling `UIApplication.sendEvent(_:)`. We read, never mutate —
/// the delivered event is handed straight back to the original implementation.
///
/// Never logs text from secure fields (`isSecureTextEntry == true`). Coordinates are
/// truncated to integers so sub-pixel jitter doesn't reveal gesture fingerprints.
final class TapTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        TapTrackerBridge.shared.install(runtime: runtime)
    }

    func stop() async {
        TapTrackerBridge.shared.disarm()
    }
}

final class TapTrackerBridge: @unchecked Sendable {
    static let shared = TapTrackerBridge()

    private let lock = NSLock()
    private var installed = false
    private var armed = false
    private weak var runtime: AppDiagLogRuntime?

    func install(runtime: AppDiagLogRuntime) {
        lock.lock(); defer { lock.unlock() }
        self.runtime = runtime
        self.armed = true
        guard !installed else { return }
        installed = true
        Self.swizzleSendEvent()
    }

    func disarm() {
        lock.lock()
        armed = false
        runtime = nil
        lock.unlock()
    }

    fileprivate func observeEvent(_ event: UIEvent) {
        guard event.type == .touches else { return }
        guard let touches = event.allTouches else { return }

        // One tap per event — we record on the .ended touch
        // ACTION_UP semantics.
        var endedTouch: UITouch?
        for t in touches where t.phase == .ended {
            endedTouch = t
            break
        }
        guard let touch = endedTouch else { return }
        guard let view = touch.view else { return }
        if Self.isInsideSecureInput(view) { return }

        lock.lock()
        let runtime = self.runtime
        let armed = self.armed
        lock.unlock()
        guard armed, let runtime else { return }

        let point = touch.location(in: nil)
        var props: [String: String] = [
            "x": String(Int(point.x)),
            "y": String(Int(point.y)),
            "target": String(describing: type(of: view))
        ]
        if let id = view.accessibilityIdentifier, !id.isEmpty {
            props["id"] = id
        }
        if let label = view.accessibilityLabel, !label.isEmpty, !Self.isInsideSecureInput(view) {
            // Accessibility labels are developer-authored and non-sensitive by convention.
            props["label"] = label
        }
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.tap,
                level: .info,
                props: props
            )
        }
    }

    private static func isInsideSecureInput(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if let field = v as? UITextField, field.isSecureTextEntry { return true }
            current = v.superview
        }
        return false
    }

    private static func swizzleSendEvent() {
        let cls: AnyClass = UIApplication.self
        let original = #selector(UIApplication.sendEvent(_:))
        let swizzled = #selector(UIApplication.appdiaglog_sendEvent(_:))
        guard
            let o = class_getInstanceMethod(cls, original),
            let s = class_getInstanceMethod(cls, swizzled)
        else { return }
        method_exchangeImplementations(o, s)
    }
}

extension UIApplication {
    @objc fileprivate func appdiaglog_sendEvent(_ event: UIEvent) {
        // After exchange this calls the *original* implementation.
        appdiaglog_sendEvent(event)
        TapTrackerBridge.shared.observeEvent(event)
    }
}
#else
final class TapTracker: Tracker, @unchecked Sendable {
    init(runtime: AppDiagLogRuntime) {}
    func start() async {}
    func stop() async {}
}
#endif
