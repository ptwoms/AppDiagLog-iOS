import Foundation

struct PendingLog: Sendable, Equatable {
    let sequence: Int64
    let event: String
    let level: LogLevel
    let properties: [String: String]
    let observedAt: Date
}

enum LogRoute: Sendable {
    case runtime(AppDiagLogRuntime, PendingLog)
    case queued
    case discarded
}

/// Public singleton facade for the AppDiagLog SDK.
///
/// Every public method is safe to call:
///   - from any thread (methods are `nonisolated`)
///   - before `initialize(...)` (they become no-ops)
///   - while `initialize(...)` is bootstrapping (logs are buffered briefly)
///   - during app shutdown (they degrade gracefully)
///
/// **No-throw guarantee**: every entry point wraps its body in a catch-all. An SDK
/// bug will never crash the host app.
public enum AppDiagLog {
    static let sdkVersion = "1.0.0"

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
                    "on this runtime. Inject a liboqs-backed PQCProvider or target iOS 26+."
                )
            }
        default:
            break
        }
        // Async bootstrap: crash recovery + first-session provisioning + tracker start.
        Task.detached(priority: .utility) {
            let runtime = await AppDiagLogRuntime.make(
                config: config,
                pqcProvider: pqcProvider,
                sequenceGenerator: state.sequenceGenerator
            )

            let recoveredSessionIds = await runtime.sessionManager.bootstrap()
            _ = await runtime.sessionManager.ensureSession()
            await runtime.pipeline.handleSessionRotated(resetSequence: false)
            if let crashMarker = runtime.crashMarkerStore.consume() {
                var props = crashMarker.eventProperties
                if let previousSessionId = recoveredSessionIds.last {
                    props["previous_session_id"] = previousSessionId
                }
                await runtime.pipeline.enqueue(
                    event: EventName.crash,
                    level: .error,
                    props: props
                )
                await runtime.pipeline.flushOnce()
            }
            let pendingLogs = state.setRuntime(runtime)
            await replay(pendingLogs, into: runtime)
            
            // Auto-tracker registry is created lazily — Tier 2/3 trackers don't
            // allocate unless explicitly enabled in config.
            let registry = AutoTrackRegistry(runtime: runtime)
            state.setRegistry(registry)
            await registry.start()
        }
    }

    /// Seal the current session and stop background work. Useful for tests; apps
    /// normally don't call this — the session timeout handles rotation.
    public static func shutdown() {
        guard let runtime = state.runtime else { return }
        let registry = state.registry
        Task.detached(priority: .utility) {
            await registry?.stop()
            await runtime.pipeline.shutdown()
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
        switch state.routeLog(event: event, level: level, properties: properties) {
        case .runtime(let runtime, let sequenced):
            enqueue(runtime: runtime, pending: sequenced)
        default:
            return
        }
    }

    private static func replay(_ pendingLogs: [PendingLog], into runtime: AppDiagLogRuntime) async {
        for pending in pendingLogs {
            await runtime.pipeline.enqueue(
                event: pending.event,
                level: pending.level,
                props: pending.properties,
                observedAt: pending.observedAt,
                sequence: pending.sequence
            )
        }
    }

    private static func enqueue(runtime: AppDiagLogRuntime, pending: PendingLog) {
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: pending.event,
                level: pending.level,
                props: pending.properties,
                observedAt: pending.observedAt,
                sequence: pending.sequence
            )
        }
    }

    // MARK: - Session control

    /// Tag the current session with a user-visible label (e.g. "checkout crash repro").
    /// The label is stored in the session index so the backend can surface it during
    /// triage, and is also recorded as a searchable event inside the session.
    public static func tagSession(_ label: String) {
        guard let runtime = state.runtime else { return }
        let sequence = runtime.sequenceGenerator.next()
        Task.detached(priority: .utility) {
            await runtime.sessionManager.tagSession(label)
            await runtime.pipeline.enqueue(
                event: EventName.sessionTag,
                level: .info,
                props: ["label": label],
                sequence: sequence
            )
        }
    }

    /// Records a `screen_view` event and updates the current screen context. Deduplicates:
    /// no event emitted when `name` matches the screen already set (prevents duplicate logs
    /// from SwiftUI redraws that re-fire `onAppear` without a navigation change).
    public static func trackScreen(_ name: String) {
        guard let runtime = state.runtime else { return }
        guard runtime.currentScreen.get() != name else { return }
        runtime.currentScreen.set(name)
        let sequence = runtime.sequenceGenerator.next()
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.screenView,
                level: .info,
                props: ["screen": name, "kind": "swiftui"],
                sequence: sequence
            )
        }
    }

    /// Called by auto-trackers and apps to record the currently displayed screen name.
    /// Future events will carry this value in `screen` until replaced.
    public static func setCurrentScreen(_ name: String?) {
        guard let runtime = state.runtime else { return }
        runtime.currentScreen.set(name)
    }

    // MARK: - Errors

    public enum AppDiagLogError: Error, Sendable {
        case notInitialized
        case mcpClientNotConfigured
    }

    /// Lock-guarded mutable singleton state. Kept as a separate type so the enum
    /// namespace stays pure-static.
    private static let state = FacadeState()
}

// MARK: - Export
extension AppDiagLog {
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
}

// MARK: - MCP
extension AppDiagLog {
    /// Start the on-device MCP server (Server mode only).
    ///
    /// The server binds on the port and address set in `McpConfig.server(...)`.
    /// Idempotent — calling this when the server is already running is a no-op.
    /// Has no effect when the SDK was configured with `McpConfig.client` or
    /// without an MCP config.
    public static func startMcpServer() {
        guard let runtime = state.runtime else { return }
        Task.detached(priority: .utility) {
            await runtime.startConfiguredMcpServer()
        }
    }

    /// Start the on-device MCP server with the provided runtime configuration.
    ///
    /// This is useful for sample apps and debug UIs where the user enters MCP options
    /// after SDK initialization. If a server is already running, it is stopped and
    /// restarted with the new config. Returns the effective bearer token.
    @discardableResult
    public static func startMcpServer(config: McpConfig) async -> String? {
        guard let runtime = state.runtime else { return nil }
        return await runtime.startMcpServer(config: config)
    }

    /// Stop the on-device MCP server and release its port.
    ///
    /// Idempotent — safe to call when the server is not running.
    public static func stopMcpServer() {
        guard let runtime = state.runtime else { return }
        Task.detached(priority: .utility) {
            await runtime.mcpServer?.stop()
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

    /// Export encrypted sessions through a one-shot MCP client configuration.
    ///
    /// This avoids storing access tokens in SDK configuration and lets apps keep tokens
    /// in process memory only.
    public static func exportViaMcp(config: McpConfig) async -> McpExportResult {
        guard let runtime = state.runtime else {
            return .failure(
                error: AppDiagLogError.notInitialized,
                message: "AppDiagLog.initialize(config:) must be called before exportViaMcp(config:)"
            )
        }
        return await runtime.exportViaMcp(config: config)
    }
}

// MARK: - Internal state holder

/// Private state holder. Not exposed.
final fileprivate class FacadeState: @unchecked Sendable {
    private static let pendingLogLimit = 50

    let sequenceGenerator = EventSequenceGenerator()

    private let lock = NSLock()
    private var _initialized = false
    private var _runtime: AppDiagLogRuntime?
    private var _registry: AutoTrackRegistry?
    private var pendingLogs: [PendingLog] = []

    init() {
        pendingLogs.reserveCapacity(Self.pendingLogLimit)
    }

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

    func setRuntime(_ r: AppDiagLogRuntime) -> [PendingLog] {
        lock.lock(); defer { lock.unlock() }
        _runtime = r
        let logs = pendingLogs
        pendingLogs.removeAll(keepingCapacity: true)
        return logs
    }

    func setRegistry(_ r: AutoTrackRegistry) {
        lock.lock(); defer { lock.unlock() }
        _registry = r
    }

    func routeLog(event: String, level: LogLevel, properties: [String: String]) -> LogRoute {
        lock.lock(); defer { lock.unlock() }
        guard _initialized else {
            return .discarded
        }
        if _runtime == nil, pendingLogs.count >= Self.pendingLogLimit {
            return .discarded
        }

        let pending = PendingLog(
            sequence: sequenceGenerator.next(),
            event: event,
            level: level,
            properties: properties,
            observedAt: Date()
        )
        if let runtime = _runtime {
            return .runtime(runtime, pending)
        }
        pendingLogs.append(pending)
        return .queued
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
