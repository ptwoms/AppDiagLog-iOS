import Foundation

/// Holds the constructed SDK dependency graph. Built once by `AppDiagLog.initialize`.
/// Wrapped as a class so we can publish it atomically.
final class AppDiagLogRuntime: @unchecked Sendable {
    static let sdkVersion = "1.0.0"

    let config: AppDiagLogConfig
    let pipeline: LogPipeline
    let sessionManager: SessionManager
    let exportManager: ExportManager
    let sessionIdHolder: SessionIdHolder
    let currentScreen: CurrentScreenHolder
    let factory: EventFactory
    let mcpServer: AppDiagLogMcpServer?
    let mcpClient: AppDiagLogMcpClient?

    init(
        config: AppDiagLogConfig,
        pipeline: LogPipeline,
        sessionManager: SessionManager,
        exportManager: ExportManager,
        sessionIdHolder: SessionIdHolder,
        currentScreen: CurrentScreenHolder,
        factory: EventFactory,
        mcpServer: AppDiagLogMcpServer?,
        mcpClient: AppDiagLogMcpClient?
    ) {
        self.config = config
        self.pipeline = pipeline
        self.sessionManager = sessionManager
        self.exportManager = exportManager
        self.sessionIdHolder = sessionIdHolder
        self.currentScreen = currentScreen
        self.factory = factory
        self.mcpServer = mcpServer
        self.mcpClient = mcpClient
    }

    static func make(config: AppDiagLogConfig, pqcProvider: PQCProvider) -> AppDiagLogRuntime {
        SdkLog.enabled = config.debugLogging
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = urls.first ?? FileManager.default.temporaryDirectory
        let paths = AppDiagLogPaths(rootDir: root)

        let indexStore = SessionIndexStore(paths: paths, maxSessions: config.maxSessions)
        let fileWriter = SessionFileWriter(paths: paths)
        let eviction = EvictionPolicy(
            paths: paths,
            maxSessions: config.maxSessions,
            maxDiskBytes: Int64(config.maxDiskUsageMB) * 1_000_000
        )

        let sessionIdHolder = SessionIdHolder()
        let screenHolder = CurrentScreenHolder()
        let factory = EventFactory(
            sessionIdProvider: { sessionIdHolder.get() },
            screenProvider: { screenHolder.get() }
        )

        let sessionManager = SessionManager(
            config: config,
            pqcProvider: pqcProvider,
            indexStore: indexStore,
            fileWriter: fileWriter,
            eviction: eviction,
            deviceMetadata: { DeviceSnapshot.capture() },
            sessionIdHolder: sessionIdHolder
        )

        let buffer = EventBuffer(
            flushThreshold: config.flushBatchSize,
            maxInMemory: config.flushBatchSize * 2
        )
        let rateLimiter = RateLimiter(
            capacity: config.maxEventsPerSecond,
            refillPerSecond: config.maxEventsPerSecond
        )
        let redaction = RedactionEngine(custom: config.redactor)

        // Circular dep: FlushCoordinator calls pipeline.flushOnce, but pipeline needs
        // FlushCoordinator. We use a class-based indirection.
        final class Ref<T>: @unchecked Sendable { var value: T?; init() {} }
        let pipelineRef = Ref<LogPipeline>()
        let flushCoordinator = FlushCoordinator(
            debounceMillis: 150,
            maxWaitMillis: config.flushIntervalMillis,
            onFlush: { [pipelineRef] in
                await pipelineRef.value?.flushOnce()
            }
        )
        let pipeline = LogPipeline(
            config: config,
            buffer: buffer,
            rateLimiter: rateLimiter,
            redaction: redaction,
            sessionManager: sessionManager,
            factory: factory,
            flusher: flushCoordinator
        )
        pipelineRef.value = pipeline

        let exportManager = ExportManager(
            paths: paths,
            indexStore: indexStore,
            sdkVersion: sdkVersion
        )

        // ─── MCP wiring (optional) ───────────────────────────────────────────
        let mcpServer: AppDiagLogMcpServer?
        let mcpClient: AppDiagLogMcpClient?
        if let mcpCfg = config.mcpConfig {
            switch mcpCfg {
            case .server:
                mcpServer = AppDiagLogMcpServer(
                    config: mcpCfg,
                    indexStore: indexStore,
                    exportManager: exportManager,
                    pipeline: pipeline,
                    sessionManager: sessionManager,
                    sdkVersion: sdkVersion
                )
                mcpClient = nil
            case .client:
                mcpServer = nil
                mcpClient = AppDiagLogMcpClient(
                    config: mcpCfg,
                    pipeline: pipeline,
                    exportManager: exportManager,
                    sdkVersion: sdkVersion
                )
            }
        } else {
            mcpServer = nil
            mcpClient = nil
        }

        return AppDiagLogRuntime(
            config: config,
            pipeline: pipeline,
            sessionManager: sessionManager,
            exportManager: exportManager,
            sessionIdHolder: sessionIdHolder,
            currentScreen: screenHolder,
            factory: factory,
            mcpServer: mcpServer,
            mcpClient: mcpClient
        )
    }
}
