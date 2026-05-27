import Foundation
#if canImport(WebKit)
import WebKit

/// Marker tracker that arms `WebViewTrackerBridge` when web-view tracking is enabled.
/// Apps report navigation events either manually via `AppDiagLog.trackWebNavigation`
/// or automatically by using `DiagLogNavigationDelegate` as their WKWebView delegate.
final class WebViewTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        WebViewTrackerBridge.shared.arm(runtime: runtime)
    }

    func stop() async {
        WebViewTrackerBridge.shared.disarm()
    }
}

final class WebViewTrackerBridge: @unchecked Sendable {
    static let shared = WebViewTrackerBridge()

    private let lock = NSLock()
    private weak var runtime: AppDiagLogRuntime?
    private var armed = false

    private init() {}

    func arm(runtime: AppDiagLogRuntime) {
        lock.lock(); self.runtime = runtime; armed = true; lock.unlock()
    }

    func disarm() {
        lock.lock(); armed = false; runtime = nil; lock.unlock()
    }

    fileprivate func record(url: URL, event: String) {
        lock.lock(); let runtime = self.runtime; let armed = self.armed; lock.unlock()
        guard armed, let runtime else { return }
        let props: [String: String] = [
            "url": RedactionEngine.redactUrl(url.absoluteString),
            "event": event
        ]
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.webView,
                level: .info,
                props: props
            )
        }
    }
}

public extension AppDiagLog {
    /// Manually record a web navigation event.
    ///
    /// `event` should be one of: `did_start`, `did_finish`, `did_fail`, `did_redirect`.
    /// URL query parameters and path IDs are stripped before storage.
    static func trackWebNavigation(url: URL, event: String = "did_finish") {
        WebViewTrackerBridge.shared.record(url: url, event: event)
    }
}

/// `WKNavigationDelegate` proxy that emits navigation events automatically.
///
/// Assign to `WKWebView.navigationDelegate` and pass your original delegate to
/// `wrapping:` so existing callbacks continue working.
///
/// ```swift
/// let diagDelegate = DiagLogNavigationDelegate(wrapping: myExistingDelegate)
/// webView.navigationDelegate = diagDelegate
/// ```
public final class DiagLogNavigationDelegate: NSObject, WKNavigationDelegate, @unchecked Sendable {
    private weak var wrapped: (any WKNavigationDelegate)?

    public init(wrapping delegate: (any WKNavigationDelegate)? = nil) {
        self.wrapped = delegate
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let url = webView.url { WebViewTrackerBridge.shared.record(url: url, event: "did_start") }
        wrapped?.webView?(webView, didStartProvisionalNavigation: navigation)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { WebViewTrackerBridge.shared.record(url: url, event: "did_finish") }
        wrapped?.webView?(webView, didFinish: navigation)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if let url = webView.url { WebViewTrackerBridge.shared.record(url: url, event: "did_fail") }
        wrapped?.webView?(webView, didFail: navigation, withError: error)
    }

    public func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        if let url = webView.url { WebViewTrackerBridge.shared.record(url: url, event: "did_redirect") }
        wrapped?.webView?(webView, didReceiveServerRedirectForProvisionalNavigation: navigation)
    }
}
#endif
