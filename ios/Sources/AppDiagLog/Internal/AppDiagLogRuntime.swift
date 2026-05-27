import Foundation

/// Holds the constructed SDK dependency graph. Built once by `AppDiagLog.initialize`.
/// Wrapped as a class so we can publish it atomically.
final class AppDiagLogRuntime: @unchecked Sendable {

    let config: AppDiagLogConfig
    let indexStore: SessionIndexStore
    let pipeline: LogPipeline
    let sessionManager: SessionManager
    let exportManager: ExportManager
    let crashMarkerStore: CrashMarkerStore
    let sessionIdHolder: SessionIdHolder
    let currentScreen: CurrentScreenHolder
    let factory: EventFactory
    let sequenceGenerator: EventSequenceGenerator
    private(set) var mcpServer: AppDiagLogMcpServer?
    private(set) var mcpClient: AppDiagLogMcpClient?

    init(
        config: AppDiagLogConfig,
        indexStore: SessionIndexStore,
        pipeline: LogPipeline,
        sessionManager: SessionManager,
        exportManager: ExportManager,
        crashMarkerStore: CrashMarkerStore,
        sessionIdHolder: SessionIdHolder,
        currentScreen: CurrentScreenHolder,
        factory: EventFactory,
        sequenceGenerator: EventSequenceGenerator,
        mcpServer: AppDiagLogMcpServer?,
        mcpClient: AppDiagLogMcpClient?
    ) {
        self.config = config
        self.indexStore = indexStore
        self.pipeline = pipeline
        self.sessionManager = sessionManager
        self.exportManager = exportManager
        self.crashMarkerStore = crashMarkerStore
        self.sessionIdHolder = sessionIdHolder
        self.currentScreen = currentScreen
        self.factory = factory
        self.sequenceGenerator = sequenceGenerator
        self.mcpServer = mcpServer
        self.mcpClient = mcpClient
    }

    static func make(
        config: AppDiagLogConfig,
        pqcProvider: PQCProvider,
        sequenceGenerator: EventSequenceGenerator = EventSequenceGenerator()
    ) async -> AppDiagLogRuntime {
        SdkLog.enabled = config.debugLogging
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = urls.first ?? FileManager.default.temporaryDirectory
        let paths = AppDiagLogPaths(rootDir: root)

        let indexStore = SessionIndexStore(paths: paths, maxSessions: config.maxSessions)
        let fileWriter = SessionFileWriter(paths: paths)
        let crashMarkerStore = CrashMarkerStore(paths: paths)
        let eviction = EvictionPolicy(
            paths: paths,
            maxSessions: config.maxSessions,
            maxDiskBytes: Int64(config.maxDiskUsageMB) * 1_000_000
        )

        let sessionIdHolder = SessionIdHolder()
        let screenHolder = CurrentScreenHolder()
        let factory = EventFactory(
            sessionIdProvider: { sessionIdHolder.get() },
            screenProvider: { screenHolder.get() },
            sequenceGenerator: sequenceGenerator
        )

        let sessionManager = SessionManager(
            config: config,
            pqcProvider: pqcProvider,
            indexStore: indexStore,
            fileWriter: fileWriter,
            eviction: eviction,
            deviceMetadata: { await DeviceSnapshot.capture() },
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
            sdkVersion: AppDiagLog.sdkVersion
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
                    sdkVersion: AppDiagLog.sdkVersion
                )
                mcpClient = nil
            case .client:
                mcpServer = nil
                mcpClient = AppDiagLogMcpClient(
                    config: mcpCfg,
                    pipeline: pipeline,
                    exportManager: exportManager,
                    sdkVersion: AppDiagLog.sdkVersion
                )
            }
        } else {
            mcpServer = nil
            mcpClient = nil
        }

        return AppDiagLogRuntime(
            config: config,
            indexStore: indexStore,
            pipeline: pipeline,
            sessionManager: sessionManager,
            exportManager: exportManager,
            crashMarkerStore: crashMarkerStore,
            sessionIdHolder: sessionIdHolder,
            currentScreen: screenHolder,
            factory: factory,
            sequenceGenerator: sequenceGenerator,
            mcpServer: mcpServer,
            mcpClient: mcpClient
        )
    }

    func startConfiguredMcpServer() async {
        await mcpServer?.start()
    }

    func startMcpServer(config: McpConfig) async -> String? {
        guard case .server = config else { return nil }

        if let mcpServer {
            await mcpServer.stop()
        }

        let server = AppDiagLogMcpServer(
            config: config,
            indexStore: indexStore,
            exportManager: exportManager,
            pipeline: pipeline,
            sessionManager: sessionManager,
            sdkVersion: AppDiagLog.sdkVersion
        )
        mcpServer = server
        await server.start()
        return server.token
    }

    func exportViaMcp(config: McpConfig) async -> McpExportResult {
        guard case .client = config else {
            return .failure(error: AppDiagLog.AppDiagLogError.mcpClientNotConfigured, message: "McpConfig.client required")
        }

        let client = AppDiagLogMcpClient(
            config: config,
            pipeline: pipeline,
            exportManager: exportManager,
            sdkVersion: AppDiagLog.sdkVersion
        )
        return await client.exportViaMcp()
    }
}
