import Foundation

/// URL-loading observer. Installs a `URLProtocol` subclass at the top of the system
/// protocol chain that **reads** request/response metadata for logging and then forwards
/// every call to the real networking stack.
///
/// Important: This intercepts only requests made through `URLSession.shared` (and any
/// session the app configures with `protocolClasses = URLProtocol.registeredClasses()`).
/// Apps that already use `URLSessionConfiguration.default` inherit our observer
/// automatically because we inject into `URLProtocol.registerClass` — which affects
/// `URLSession.shared`.
///
/// We never log bodies or sensitive headers — redaction runs on props before enqueue.
final class URLProtocolTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        AppDiagLogURLProtocol.runtime = runtime
        URLProtocol.registerClass(AppDiagLogURLProtocol.self)
    }

    func stop() async {
        URLProtocol.unregisterClass(AppDiagLogURLProtocol.self)
        AppDiagLogURLProtocol.runtime = nil
    }
}

/// URLProtocol that observes requests and delegates the actual loading to a nested
/// URLSession. We match every HTTP(S) request exactly once — the `handledKey` marker
/// prevents infinite recursion when our inner session triggers the protocol again.
final class AppDiagLogURLProtocol: URLProtocol, @unchecked Sendable, URLSessionDataDelegate, URLSessionTaskDelegate {
    // `nonisolated(unsafe)` because `URLProtocol.canInit(with:)` is a class method that
    // the URL loading system invokes from private queues — we can't make it async.
    nonisolated(unsafe) static weak var runtime: AppDiagLogRuntime?
    private static let handledKey = "com.appdiaglog.handled"

    private var innerTask: URLSessionDataTask?
    private var responseData = Data()
    private var startTime: CFAbsoluteTime = 0
    private var observedResponse: URLResponse?

    override class func canInit(with request: URLRequest) -> Bool {
        guard runtime != nil else { return false }
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            // Should not happen; fail loudly-but-safely.
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        startTime = CFAbsoluteTimeGetCurrent()

        let config = URLSessionConfiguration.ephemeral
        // Critical: do NOT include our own protocol in the inner session, otherwise
        // we'd loop forever.
        config.protocolClasses = []
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        innerTask = session.dataTask(with: mutable as URLRequest)
        innerTask?.resume()
    }

    override func stopLoading() {
        innerTask?.cancel()
        innerTask = nil
    }

    // MARK: - URLSession delegate forwarding

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        observedResponse = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
        emitEvent(error: error, elapsedMs: elapsedMs)
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        session.invalidateAndCancel()
    }

    // MARK: - Emit

    private func emitEvent(error: Error?, elapsedMs: Int) {
        guard let runtime = Self.runtime else { return }
        let request = self.request
        let http = observedResponse as? HTTPURLResponse
        var props: [String: String] = [
            "method": request.httpMethod ?? "GET",
            "url": RedactionEngine.redactUrl(request.url?.absoluteString ?? ""),
            "duration_ms": String(elapsedMs)
        ]
        if let status = http?.statusCode {
            props["status"] = String(status)
        }
        if let error = error {
            props["error"] = String(describing: error)
        }
        let level: LogLevel = {
            if error != nil { return .error }
            if let s = http?.statusCode, s >= 500 { return .error }
            if let s = http?.statusCode, s >= 400 { return .warning }
            return .info
        }()
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.apiCall,
                level: level,
                props: props
            )
        }
    }
}
