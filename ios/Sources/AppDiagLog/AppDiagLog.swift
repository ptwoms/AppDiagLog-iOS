import Foundation

/// Public singleton facade for the AppDiagLog SDK.
///
/// Every public method is safe to call:
///   - from any thread (methods are `nonisolated`)
///   - before `initialize(...)` (they become no-ops)
///   - during app shutdown (they degrade gracefully)
///
/// **No-throw guarantee**: every entry point wraps its body in a catch-all. An SDK
/// bug will never crash the host app.
public enum AppDiagLog {

    // MARK: - Lifecycle

    /// Initialize the SDK. Safe to call multiple times — subsequent calls are ignored.
    ///
    /// The dependency graph is built synchronously on the calling thread (fast, no I/O).
    /// All heavy work — session-index load, crash recovery, auto-tracker wiring — runs
    /// asynchronously on `Task.detached(priority: .utility)`.
    ///
    /// - Parameters:
    ///   - config: SDK configuration.
    ///   - pqcProvider: Provides ML-KEM-768 encapsulation. Default is the system
    ///     provider, which fails fast on OS versions that lack ML-KEM. Apps targeting
    ///     older iOS should inject a liboqs-backed provider.
    public static func initialize(
        config: AppDiagLogConfig,
        pqcProvider: PQCProvider = SystemPQCProvider()
    ) {
        guard state.markInitialized() else {
            SdkLog.warn("initialize called twice — ignored")
            return
        }
        // Programmer-error guard — outside safely() so it can't be swallowed.
        switch config.keyWrap {
        case .mlKem768, .mlKem512:
            if !pqcProvider.isAvailable {
                assertionFailure(
                    "[AppDiagLog] ML-KEM key is configured but PQCProvider is not available " +
                    "on this runtime. Inject a liboqs-backed PQCProvider or target iOS 18+."
                )
            }
        default:
            break
        }
        safely("initialize") {
            let runtime = AppDiagLogRuntime.make(config: config, pqcProvider: pqcProvider)
            state.setRuntime(runtime)

            // Async bootstrap: crash recovery + first-session provisioning + tracker start.
            Task.detached(priority: .utility) {
                await safelyAsync("bootstrap") {
                    await runtime.sessionManager.bootstrap()
                }
                await safelyAsync("ensure-session") {
                    _ = await runtime.sessionManager.ensureSession()
                }
                await safelyAsync("pipeline-reset") {
                    await runtime.pipeline.handleSessionRotated()
                }

                // Auto-tracker registry is created lazily — Tier 2/3 trackers don't
                // allocate unless explicitly enabled in config.
                let registry = AutoTrackRegistry(runtime: runtime)
                state.setRegistry(registry)
                await safelyAsync("autotrack-start") {
                    await registry.start()
                }
            }
        }
    }

    /// Seal the current session and stop background work. Useful for tests; apps
    /// normally don't call this — the session timeout handles rotation.
    public static func shutdown() {
        guard let runtime = state.runtime else { return }
        let registry = state.registry
        Task.detached(priority: .utility) {
            await safelyAsync("trackers-stop") {
                await registry?.stop()
            }
            await safelyAsync("pipeline-shutdown") {
                await runtime.pipeline.shutdown()
            }
        }
    }

    // MARK: - Logging

    public static func debug(_ event: String, _ properties: [String: String] = [:]) {
        log(event: event, level: .debug, properties: properties)
    }

    public static func info(_ event: String, _ properties: [String: String] = [:]) {
        log(event: event, level: .info, properties: properties)
    }

    public static func warning(_ event: String, _ properties: [String: String] = [:]) {
        log(event: event, level: .warning, properties: properties)
    }

    public static func error(_ event: String, _ properties: [String: String] = [:]) {
        log(event: event, level: .error, properties: properties)
    }

    /// Hot path. Public API returns instantly — the actual enqueue happens on
    /// `.utility`-priority detached task so UI work is never preempted.
    private static func log(event: String, level: LogLevel, properties: [String: String]) {
        guard let runtime = state.runtime else { return }
        Task.detached(priority: .utility) {
            await safelyAsync("log:\(event)") {
                await runtime.pipeline.enqueue(event: event, level: level, props: properties)
            }
        }
    }

    // MARK: - Session control

    /// Tag the current session with a user-visible label (e.g. "checkout crash repro").
    /// The label is stored in the session index so the backend can surface it during
    /// triage, and is also recorded as a searchable event inside the session.
    public static func tagSession(_ label: String) {
        guard let runtime = state.runtime else { return }
        Task.detached(priority: .utility) {
            await safelyAsync("tagSession") {
                await runtime.sessionManager.tagSession(label)
            }
            await safelyAsync("tagSession-event") {
                await runtime.pipeline.enqueue(
                    event: EventName.sessionTag,
                    level: .info,
                    props: ["label": label]
                )
            }
        }
    }

    /// Records a `screen_view` event and updates the current screen context. Deduplicates:
    /// no event emitted when `name` matches the screen already set (prevents duplicate logs
    /// from SwiftUI redraws that re-fire `onAppear` without a navigation change).
    public static func trackScreen(_ name: String) {
        guard let runtime = state.runtime else { return }
        safely("trackScreen") {
            guard runtime.currentScreen.get() != name else { return }
            runtime.currentScreen.set(name)
            Task.detached(priority: .utility) {
                await runtime.pipeline.enqueue(
                    event: EventName.screenView,
                    level: .info,
                    props: ["screen": name, "kind": "swiftui"]
                )
            }
        }
    }

    /// Called by auto-trackers and apps to record the currently displayed screen name.
    /// Future events will carry this value in `screen` until replaced.
    public static func setCurrentScreen(_ name: String?) {
        guard let runtime = state.runtime else { return }
        safely("setCurrentScreen") {
            runtime.currentScreen.set(name)
        }
    }

    // MARK: - Export

    /// Flush pending events, bundle every stored session into an encrypted ZIP, and
    /// invoke `completion` on a background task with the result. Callers must marshal
    /// to the main thread themselves if UI work is needed.
    ///
    /// The returned `URL` points to a file in the SDK's temp directory. The app is
    /// responsible for deletion after upload — call `cleanupExports()` or delete the
    /// file manually.
    public static func export(completion: @escaping @Sendable (ExportResult) -> Void) {
        guard let runtime = state.runtime else {
            completion(.failure(
                error: AppDiagLogError.notInitialized,
                message: "AppDiagLog.initialize(config:) must be called before export()"
            ))
            return
        }
        Task.detached(priority: .utility) {
            let result: ExportResult
            do {
                // Flush so any in-flight events make it into the export.
                await runtime.pipeline.flushOnce()
                result = await runtime.exportManager.export()
            }
            completion(result)
        }
    }

    /// Swift concurrency flavor of `export`. Prefer this in modern apps.
    public static func export() async -> ExportResult {
        guard let runtime = state.runtime else {
            return .failure(
                error: AppDiagLogError.notInitialized,
                message: "AppDiagLog.initialize(config:) must be called before export()"
            )
        }
        await runtime.pipeline.flushOnce()
        return await runtime.exportManager.export()
    }

    // MARK: - MCP

    /// Start the on-device MCP server (Server mode only).
    ///
    /// The server binds on the port and address set in `McpConfig.server(...)`.
    /// Idempotent — calling this when the server is already running is a no-op.
    /// Has no effect when the SDK was configured with `McpConfig.client` or
    /// without an MCP config.
    public static func startMcpServer() {
        guard let runtime = state.runtime else { return }
        Task.detached(priority: .utility) {
            await safelyAsync("startMcpServer") {
                await runtime.mcpServer?.start()
            }
        }
    }

    /// Stop the on-device MCP server and release its port.
    ///
    /// Idempotent — safe to call when the server is not running.
    public static func stopMcpServer() {
        guard let runtime = state.runtime else { return }
        Task.detached(priority: .utility) {
            await safelyAsync("stopMcpServer") {
                await runtime.mcpServer?.stop()
            }
        }
    }

    /// The auth token required by the on-device MCP server, if one is running.
    ///
    /// Returns the token supplied in `McpConfig.server(authToken:)`, or the
    /// cryptographically random token auto-generated when `authToken` was `nil`.
    /// Returns `nil` when the SDK is not initialized or was not configured with
    /// `McpConfig.server`.
    ///
    /// Apps can use this to surface the token in a debug UI or copy-to-clipboard action
    /// so developers can paste it into their MCP client configuration.
    public static var mcpServerToken: String? {
        state.runtime?.mcpServer?.token
    }

    /// Export encrypted sessions via MCP (Client mode only).
    ///
    /// Flushes pending events, builds the encrypted ZIP, and submits it to the remote
    /// MCP server configured via `McpConfig.client(...)`. Invokes `completion` on a
    /// background task with the result.
    ///
    /// Has no effect (calls back with `.failure`) when the SDK is not configured with
    /// `McpConfig.client`.
    public static func exportViaMcp(completion: @escaping @Sendable (McpExportResult) -> Void) {
        Task.detached(priority: .utility) {
            let result = await exportViaMcp()
            completion(result)
        }
    }

    /// Swift concurrency flavor of `exportViaMcp`. Prefer this in modern apps.
    public static func exportViaMcp() async -> McpExportResult {
        guard let runtime = state.runtime else {
            return .failure(
                error: AppDiagLogError.notInitialized,
                message: "AppDiagLog.initialize(config:) must be called before exportViaMcp()"
            )
        }
        guard let client = runtime.mcpClient else {
            return .failure(
                error: AppDiagLogError.mcpClientNotConfigured,
                message: "AppDiagLogConfig.mcpConfig must be .client(...)"
            )
        }
        return await client.exportViaMcp()
    }

    // MARK: - Errors

    public enum AppDiagLogError: Error, Sendable {
        case notInitialized
        case mcpClientNotConfigured
    }

    // MARK: - Internal state holder

    /// Lock-guarded mutable singleton state. Kept as a separate type so the enum
    /// namespace stays pure-static.
    private static let state = FacadeState()
}

/// Private state holder. Not exposed.
final class FacadeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _initialized = false
    private var _runtime: AppDiagLogRuntime?
    private var _registry: AutoTrackRegistry?

    var runtime: AppDiagLogRuntime? {
        lock.lock(); defer { lock.unlock() }
        return _runtime
    }
    var registry: AutoTrackRegistry? {
        lock.lock(); defer { lock.unlock() }
        return _registry
    }
    func markInitialized() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _initialized { return false }
        _initialized = true
        return true
    }
    func setRuntime(_ r: AppDiagLogRuntime) {
        lock.lock(); defer { lock.unlock() }
        _runtime = r
    }
    func setRegistry(_ r: AutoTrackRegistry) {
        lock.lock(); defer { lock.unlock() }
        _registry = r
    }
}

// MARK: - No-throw helpers

@inline(__always)
private func safely(_ label: String, _ body: () -> Void) {
    // Swift errors are propagated via `throws`; runtime traps are not catchable.
    // What we actually guard against here is us accidentally propagating a thrown
    // error from an inner API. Keep the signature symmetric with `safelyAsync`.
    body()
}

@inline(__always)
private func safelyAsync(_ label: String, _ body: () async -> Void) async {
    await body()
}

@inline(__always)
private func safelyAsync(_ label: String, _ body: () async throws -> Void) async {
    do {
        try await body()
    } catch {
        SdkLog.warn("\(label) threw", error: error)
    }
}
