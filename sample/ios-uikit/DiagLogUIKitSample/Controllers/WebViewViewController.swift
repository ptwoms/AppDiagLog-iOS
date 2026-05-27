import UIKit
import WebKit
import AppDiagLog

final class WebViewViewController: UIViewController {
    private var webView: WKWebView!
    private lazy var diagDelegate = DiagLogNavigationDelegate(wrapping: self)

    private let urlBar = UITextField()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let backButton = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"), style: .plain, target: nil, action: nil)
    private let forwardButton = UIBarButtonItem(image: UIImage(systemName: "chevron.forward"), style: .plain, target: nil, action: nil)
    private let reloadButton = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), style: .plain, target: nil, action: nil)

    private var kvoProgressObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "WebView"
        view.backgroundColor = .systemBackground
        setupWebView()
        setupURLBar()
        setupProgressView()
        setupToolbar()
        loadURL("https://example.com")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AppDiagLog.setCurrentScreen("WebViewScreen")
    }

    deinit {
        kvoProgressObservation?.invalidate()
    }

    // MARK: - Setup

    private func setupWebView() {
        webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = diagDelegate
        view.addSubview(webView)
    }

    private func setupURLBar() {
        urlBar.placeholder = "https://example.com"
        urlBar.keyboardType = .URL
        urlBar.autocorrectionType = .no
        urlBar.autocapitalizationType = .none
        urlBar.returnKeyType = .go
        urlBar.clearButtonMode = .whileEditing
        urlBar.borderStyle = .roundedRect
        urlBar.font = .systemFont(ofSize: 14)
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.delegate = self
        view.addSubview(urlBar)
    }

    private func setupProgressView() {
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.tintColor = .systemBlue
        view.addSubview(progressView)

        kvoProgressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] webView, _ in
            DispatchQueue.main.async {
                self?.progressView.progress = Float(webView.estimatedProgress)
                self?.progressView.isHidden = !webView.isLoading
            }
        }
    }

    private func setupToolbar() {
        navigationController?.isToolbarHidden = false

        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.isEnabled = false

        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        forwardButton.isEnabled = false

        reloadButton.target = self
        reloadButton.action = #selector(reloadOrStop)

        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        toolbarItems = [backButton, spacer, forwardButton, spacer, reloadButton]

        // Layout: urlBar top, progressView below urlBar, webView fills rest above toolbar
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            urlBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            urlBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 12),
            urlBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -12),

            progressView.topAnchor.constraint(equalTo: urlBar.bottomAnchor, constant: 4),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            webView.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 4),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }

    // MARK: - Navigation

    private func loadURL(_ raw: String) {
        var urlString = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        guard let url = URL(string: urlString) else { return }
        urlBar.text = urlString
        webView.load(URLRequest(url: url))
    }

    private func updateControls() {
        backButton.isEnabled = webView.canGoBack
        forwardButton.isEnabled = webView.canGoForward
        reloadButton.image = UIImage(systemName: webView.isLoading ? "xmark" : "arrow.clockwise")
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }
}

// MARK: - UITextFieldDelegate

extension WebViewViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        loadURL(textField.text ?? "")
        return true
    }
}

// MARK: - WKNavigationDelegate (UI state updates; SDK tracking via DiagLogNavigationDelegate)

extension WebViewViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        urlBar.text = webView.url?.absoluteString
        updateControls()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        urlBar.text = webView.url?.absoluteString
        updateControls()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        updateControls()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        updateControls()
    }
}
