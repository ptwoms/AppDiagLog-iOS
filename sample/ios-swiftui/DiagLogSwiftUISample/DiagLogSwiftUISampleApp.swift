import Foundation
import SwiftUI
import Combine
import AppDiagLog

enum SampleConfiguration {
    enum DefaultsKey {
        static let enableMcpClient = "sample.mcp.client.enabled"
        static let enableMcpServer = "sample.mcp.server.enabled"
        static let mcpClientURL = "sample.mcp.client.url"
        static let mcpClientToolName = "sample.mcp.client.toolName"
        static let mcpServerPort = "sample.mcp.server.port"
        static let mcpServerBindAddress = "sample.mcp.server.bindAddress"
    }

    static let defaultMcpClientURL = "http://localhost:8080/api/v1/mcp"
    static let defaultMcpClientToolName = "submit_diagnostics"
    static let defaultMcpServerPort = 7321
    static let defaultMcpServerBindAddress = "127.0.0.1"

    static let placeholderPublicKey = "REPLACE_WITH_YOUR_BASE64_PUBLIC_KEY"
    static let sampleKeyBase64 = placeholderPublicKey
    static let sampleKeyID = "sample-key-2026-04"
    static let keyBytes: Data = {
        if sampleKeyBase64 == placeholderPublicKey {
            assertionFailure("Replace SampleConfiguration.sampleKeyBase64 with a real public key before running the sample.")
            return Data()
        }
        return Data(base64Encoded: sampleKeyBase64) ?? Data()
    }()

    static let maxSessions = 5
    static let maxEventsPerSession = 1_000
    static let maxDiskUsageMB = 10
    static let flushBatchSize = 50
    static let flushIntervalMillis: UInt64 = 5_000
    static let flushMaxWaitMillis: UInt64 = 10_000
    static let sessionTimeoutMinutes = 30
    static let maxEventsPerSecond = 100

    static var enableMcpClient: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.enableMcpClient)
    }
    static var enableMcpServer: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.enableMcpServer)
    }
    static var sampleMcpClientURL: String {
        stringDefault(DefaultsKey.mcpClientURL, defaultMcpClientURL)
    }
    static var sampleMcpClientToolName: String {
        stringDefault(DefaultsKey.mcpClientToolName, defaultMcpClientToolName)
    }
    static var sampleMcpServerPort: UInt16 {
        UInt16(intDefault(DefaultsKey.mcpServerPort, defaultMcpServerPort))
    }
    static var sampleMcpServerBindAddress: String {
        stringDefault(DefaultsKey.mcpServerBindAddress, defaultMcpServerBindAddress)
    }

    static let autoTrack = AutoTrackConfig(
        appLifecycle: true,
        screenViews: nil,
        taps: true,
        apiCalls: true,
        crashes: true,
        connectivity: true,
        deepLinks: true,
        deviceSnapshot: true,
        memoryPressure: true,
        batteryThermal: true,
        permissionChanges: PermissionTrackConfig(permissions: Set(TrackedPermission.allCases), trigger: .didBecomeActive),
        pushNotifications: true,
        webViews: true,
        backgroundTasks: true,
        preferenceChanges: true
    )

    static var mcpConfig: McpConfig? {
        return nil
    }

    static var sdkConfig: AppDiagLogConfig {
        AppDiagLogConfig(
            maxSessions: maxSessions,
            maxEventsPerSession: maxEventsPerSession,
            maxDiskUsageMB: maxDiskUsageMB,
            flushBatchSize: flushBatchSize,
            flushIntervalMillis: flushIntervalMillis,
            flushMaxWaitMillis: flushMaxWaitMillis,
            sessionTimeoutMinutes: sessionTimeoutMinutes,
            maxEventsPerSecond: maxEventsPerSecond,
            // RSA keeps this sample runnable on iOS 16+ without an extra PQC provider.
            // Swap to `.mlKem768(...)` with a real key when you are ready to test PQC.
            keyWrap: .rsaOaep3072(keyId: sampleKeyID, publicKey: keyBytes),
            symmetric: .aes256gcm,
            autoTrack: autoTrack,
            debugLogging: true,
            mcpConfig: mcpConfig
        )
    }

    static var mcpModeDescription: String {
        if enableMcpClient { return "Client" }
        if enableMcpServer { return "Server" }
        return "Disabled"
    }

    static func stringDefault(_ key: String, _ fallback: String) -> String {
        guard let value = UserDefaults.standard.string(forKey: key),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return value
    }

    static func intDefault(_ key: String, _ fallback: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : fallback
    }

    static let uploadEndpoint = "http://localhost:8080/api/v1/diagnostics/upload"
    static let uploadBearerToken = "dev-only-replace-me"
    static let sdkVersionLabel = "Local AppDiagLog package"
}

@MainActor
final class SampleMcpRuntimeState: ObservableObject {
    static let shared = SampleMcpRuntimeState()

    @Published var clientAuthToken = ""
    @Published var serverAuthToken: String?
    @Published var isServerRunning = false
    @Published var serverStatus: String?

    private init() {}
}

@main
struct DiagLogSwiftUISampleApp: App {
    init() {
        AppDiagLog.initialize(config: SampleConfiguration.sdkConfig)
        NotificationHandler.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .trackScreen("RootTabView")
                .trackDeepLinks()
        }
    }
}
