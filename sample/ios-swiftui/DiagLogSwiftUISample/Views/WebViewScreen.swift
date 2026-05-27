import SwiftUI
import WebKit
import Combine
import AppDiagLog

struct WebViewScreen: View {
    @State private var urlBarText = "https://example.com"
    @State private var loadedURL = URL(string: "https://example.com")!
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var reloadWebView = false
    @State private var navLog = [LogEntry("Navigate to a URL to see WebView tracking events.")]
    @StateObject private var controller = WebViewController()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
                TextField("URL", text: $urlBarText)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .autocapitalization(.none)
                    .onSubmit { navigate() }
                    .font(.footnote)
                if isLoading {
                    ProgressView().scaleEffect(0.8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            WebViewRepresentable(
                url: $loadedURL,
                isLoading: $isLoading,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                reloadWebView: $reloadWebView,
                controller: controller,
                onEvent: { event, urlStr in navLog.append("\(event) — \(urlStr)") }
            )

            Divider()

            HStack(spacing: 32) {
                Button { controller.goBack() } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!canGoBack)

                Button { controller.goForward() } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!canGoForward)

                Button { controller.stopOrReload() } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                }

                NavigationLink {
                    List(navLog) { entry in
                        Text(entry.message).font(.footnote.monospaced())
                    }
                    .navigationTitle("Nav Events")
                } label: {
                    Image(systemName: "list.bullet.clipboard")
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .navigationTitle("WebView")
        .navigationBarTitleDisplayMode(.inline)
        .trackScreen("WebViewScreen")
    }

    private func navigate() {
        var raw = urlBarText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.hasPrefix("http://") && !raw.hasPrefix("https://") {
            raw = "https://" + raw
        }
        urlBarText = raw
        if let url = URL(string: raw) {
            loadedURL = url
        }
    }
}

// MARK: - Controller

@MainActor
final class WebViewController: ObservableObject {
    weak var webView: WKWebView?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func stopOrReload() {
        guard let webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }
}

// MARK: - UIViewRepresentable

private struct WebViewRepresentable: UIViewRepresentable {
    @Binding var url: URL
    @Binding var isLoading: Bool
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var reloadWebView: Bool
    
    let controller: WebViewController
    let onEvent: (String, String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isLoading: $isLoading,
            canGoBack: $canGoBack,
            canGoForward: $canGoForward,
            onEvent: onEvent
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        // DiagLogNavigationDelegate wraps the coordinator so both SDK tracking and
        // UI-state updates happen automatically on every navigation event.
        webView.navigationDelegate = context.coordinator.diagDelegate
        controller.webView = webView
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if reloadWebView {
            reloadWebView = false
            webView.load(URLRequest(url: url))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var canGoBack: Bool
        @Binding var canGoForward: Bool
        let onEvent: (String, String) -> Void
        lazy var diagDelegate = DiagLogNavigationDelegate(wrapping: self)

        init(
            isLoading: Binding<Bool>,
            canGoBack: Binding<Bool>,
            canGoForward: Binding<Bool>,
            onEvent: @escaping (String, String) -> Void
        ) {
            _isLoading = isLoading
            _canGoBack = canGoBack
            _canGoForward = canGoForward
            self.onEvent = onEvent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
            onEvent("did_start", webView.url?.host ?? "—")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
            onEvent("did_finish", webView.url?.absoluteString ?? "—")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            canGoBack = webView.canGoBack
            canGoForward = webView.canGoForward
            onEvent("did_fail", (error as NSError).localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            isLoading = false
            onEvent("did_fail_provisional", (error as NSError).localizedDescription)
        }
    }
}
