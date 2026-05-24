import Foundation

/// Public configuration for the AppDiagLog SDK.
///
/// Defaults are tuned for: <100KB steady-state memory, zero main-thread blocking.
public struct AppDiagLogConfig: Sendable {
    public let maxSessions: Int
    public let maxEventsPerSession: Int
    public let maxDiskUsageMB: Int
    public let flushBatchSize: Int
    public let flushIntervalMillis: UInt64
    public let flushMaxWaitMillis: UInt64
    public let sessionTimeoutMinutes: Int
    public let maxEventsPerSecond: Int
    /// Asymmetric key used to wrap each per-session DEK. The case picks the algorithm.
    public let keyWrap: AsymmetricKey
    /// Symmetric AEAD used for the per-flush payload. Default: AES-256-GCM.
    public let symmetric: SymmetricAlgorithm
    public let autoTrack: AutoTrackConfig
    public let redactor: (@Sendable (EventEnvelope) -> EventEnvelope)?
    public let debugLogging: Bool

    /// Optional MCP (Model Context Protocol) configuration.
    ///
    /// - `.server(...)`: starts an on-device HTTP server so AI agents can pull encrypted
    ///   session data via the MCP protocol.
    /// - `.client(...)`: the SDK acts as an MCP client that pushes the encrypted export
    ///   ZIP to a remote MCP server on demand.
    ///
    /// `nil` (default) disables MCP entirely.
    public let mcpConfig: McpConfig?

    public init(
        maxSessions: Int = 5,
        maxEventsPerSession: Int = 1_000,
        maxDiskUsageMB: Int = 10,
        flushBatchSize: Int = 50,
        flushIntervalMillis: UInt64 = 5_000,
        flushMaxWaitMillis: UInt64 = 10_000,
        sessionTimeoutMinutes: Int = 30,
        maxEventsPerSecond: Int = 100,
        keyWrap: AsymmetricKey,
        symmetric: SymmetricAlgorithm = .aes256gcm,
        autoTrack: AutoTrackConfig = AutoTrackConfig(),
        redactor: (@Sendable (EventEnvelope) -> EventEnvelope)? = nil,
        debugLogging: Bool = false,
        mcpConfig: McpConfig? = nil
    ) {
        self.maxSessions = maxSessions
        self.maxEventsPerSession = maxEventsPerSession
        self.maxDiskUsageMB = maxDiskUsageMB
        self.flushBatchSize = flushBatchSize
        self.flushIntervalMillis = flushIntervalMillis
        self.flushMaxWaitMillis = flushMaxWaitMillis
        self.sessionTimeoutMinutes = sessionTimeoutMinutes
        self.maxEventsPerSecond = maxEventsPerSecond
        self.keyWrap = keyWrap
        self.symmetric = symmetric
        self.autoTrack = autoTrack
        self.redactor = redactor
        self.debugLogging = debugLogging
        self.mcpConfig = mcpConfig
    }
}

public struct AutoTrackConfig: Sendable {
    public let appLifecycle: Bool
    public let screenViews: Bool
    public let taps: Bool
    public let apiCalls: Bool
    public let crashes: Bool
    public let connectivity: Bool
    public let deepLinks: Bool
    public let deviceSnapshot: Bool
    public let memoryPressure: Bool
    public let batteryThermal: Bool
    public let permissionChanges: Bool
    public let pushNotifications: Bool
    public let webViews: Bool
    public let backgroundTasks: Bool
    public let preferenceChanges: Bool

    public init(
        appLifecycle: Bool = true,
        screenViews: Bool = true,
        taps: Bool = true,
        apiCalls: Bool = true,
        crashes: Bool = true,
        connectivity: Bool = true,
        deepLinks: Bool = true,
        deviceSnapshot: Bool = true,
        memoryPressure: Bool = true,
        batteryThermal: Bool = true,
        permissionChanges: Bool = true,
        pushNotifications: Bool = false,
        webViews: Bool = false,
        backgroundTasks: Bool = false,
        preferenceChanges: Bool = false
    ) {
        self.appLifecycle = appLifecycle
        self.screenViews = screenViews
        self.taps = taps
        self.apiCalls = apiCalls
        self.crashes = crashes
        self.connectivity = connectivity
        self.deepLinks = deepLinks
        self.deviceSnapshot = deviceSnapshot
        self.memoryPressure = memoryPressure
        self.batteryThermal = batteryThermal
        self.permissionChanges = permissionChanges
        self.pushNotifications = pushNotifications
        self.webViews = webViews
        self.backgroundTasks = backgroundTasks
        self.preferenceChanges = preferenceChanges
    }
}

/// Asymmetric key used to wrap per-session DEKs. The case picks the algorithm
/// (ML-KEM-768/512, RSA-OAEP-3072, or ECDH-P256+HKDF). `keyId` must match an
/// entry in the backend's key vault so it can pick the private half.
public enum AsymmetricKey: Sendable, Equatable {
    case mlKem768(keyId: String, publicKey: Data)
    case mlKem512(keyId: String, publicKey: Data)
    case rsaOaep3072(keyId: String, publicKey: Data)
    case ecdhP256(keyId: String, publicKey: Data)

    public var keyId: String {
        switch self {
        case .mlKem768(let id, _), .mlKem512(let id, _),
             .rsaOaep3072(let id, _), .ecdhP256(let id, _):
            return id
        }
    }

    public var algorithmId: String {
        switch self {
        case .mlKem768: return "ML-KEM-768"
        case .mlKem512: return "ML-KEM-512"
        case .rsaOaep3072: return "RSA-OAEP-3072"
        case .ecdhP256: return "ECDH-P256+HKDF"
        }
    }
}
