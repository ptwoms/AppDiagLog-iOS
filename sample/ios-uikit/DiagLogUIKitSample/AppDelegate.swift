import UIKit
import Foundation
import AppDiagLog

enum SampleConfiguration {
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

    static let enableMcpClient = false
    static let enableMcpServer = false
    static let sampleMcpClientURL = "https://mcp.example.com/rpc"
    static let sampleMcpAuthToken = "REPLACE_WITH_MCP_TOKEN"
    static let sampleMcpToolName = "submit_diagnostics"
    static let sampleMcpServerPort: UInt16 = 7321
    static let sampleMcpServerBindAddress = "127.0.0.1"

    static let keyWrap: AsymmetricKey = .rsaOaep3072(keyId: sampleKeyID, publicKey: keyBytes)
    static let symmetric: SymmetricAlgorithm = .aes256gcm

    static let autoTrack = AutoTrackConfig(
        appLifecycle: true,
        screenViews: true,
        taps: true,
        apiCalls: true,
        crashes: true,
        connectivity: true,
        deepLinks: true,
        deviceSnapshot: true,
        memoryPressure: true,
        batteryThermal: true,
        permissionChanges: true,
        pushNotifications: true,
        webViews: true,
        backgroundTasks: true,
        preferenceChanges: true
    )

    static var mcpConfig: McpConfig? {
        if enableMcpClient {
            return .client(
                serverUrl: sampleMcpClientURL,
                authToken: sampleMcpAuthToken,
                toolName: sampleMcpToolName
            )
        }

        if enableMcpServer {
            return .server(
                port: sampleMcpServerPort,
                authToken: sampleMcpAuthToken,
                bindAddress: sampleMcpServerBindAddress
            )
        }

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
            keyWrap: keyWrap,
            symmetric: symmetric,
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

    static var keyWrapDescription: String {
        switch keyWrap {
        case .mlKem768:
            return "ML-KEM-768"
        case .mlKem512:
            return "ML-KEM-512"
        case .rsaOaep3072:
            return "RSA-OAEP-3072"
        case .ecdhP256:
            return "ECDH-P256+HKDF"
        }
    }

    static let uploadEndpoint = "http://localhost:8080/api/v1/diagnostics/upload"
    static let uploadBearerToken = "dev-only-replace-me"
    static let sdkVersionLabel = "Local AppDiagLog package"
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDiagLog.initialize(config: SampleConfiguration.sdkConfig)

        if SampleConfiguration.enableMcpServer {
            AppDiagLog.startMcpServer()
        }

        AppDiagLog.info(
            "sample_app_launch",
            [
                "sample": "ios-uikit",
                "ui": "uikit-plus-swiftui",
                "mcp_mode": SampleConfiguration.mcpModeDescription
            ]
        )
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppDiagLog.stopMcpServer()
        AppDiagLog.shutdown()
    }
}
