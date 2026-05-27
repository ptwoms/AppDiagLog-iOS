import UIKit
import Foundation
import Combine
import UserNotifications
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

    static let maxSessions = 15
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

    static let keyWrap: AsymmetricKey = .rsaOaep3072(keyId: sampleKeyID, publicKey: keyBytes)
    static let symmetric: SymmetricAlgorithm = .aes256gcm

    static let autoTrack = AutoTrackConfig(
        appLifecycle: true,
        screenViews: ScreenTrackingConfig(),
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
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AppDiagLog.initialize(config: SampleConfiguration.sdkConfig)
        registerNotificationCategories()

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

    private func registerNotificationCategories() {
        let viewAction = UNNotificationAction(
            identifier: "view_order",
            title: "View Order",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: "dismiss_order",
            title: "Dismiss",
            options: .destructive
        )
        let orderCategory = UNNotificationCategory(
            identifier: "order_update",
            actions: [viewAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([orderCategory])
        UNUserNotificationCenter.current().delegate = self
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

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AppDiagLog.trackPushReceived(
            categoryIdentifier: notification.request.content.categoryIdentifier
        )
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        AppDiagLog.trackPushInteraction(
            actionIdentifier: response.actionIdentifier,
            categoryIdentifier: response.notification.request.content.categoryIdentifier
        )
        completionHandler()
    }
}
