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

/// The set of permission types that `PermissionChangeTracker` can monitor.
public enum TrackedPermission: CaseIterable, Sendable {
    case camera
    case microphone
    case photos
    case location
    case notifications
    case contacts
    case calendar
    case reminders
    case speechRecognition
    case motionFitness
    case appTracking
}

/// Controls when `PermissionChangeTracker` re-snapshots authorization statuses.
///
/// - `willEnterForeground`: fires once per foreground transition. Catches changes made
///   in the iOS Settings app. Lower frequency.
/// - `didBecomeActive`: fires on every active transition, including after an in-app
///   permission alert is dismissed. Also catches changes from Settings. Higher frequency
///   but status reads are cheap so overhead remains negligible.
public enum PermissionCheckTrigger: Sendable {
    case willEnterForeground
    case didBecomeActive
}

/// Specifies which permission types `PermissionChangeTracker` monitors.
///
/// Pass `nil` for `permissionChanges` in `AutoTrackConfig` to disable the tracker entirely.
/// Use `PermissionTrackConfig(permissions: [...])` to monitor only a subset.
public struct PermissionTrackConfig: Sendable {
    public let permissions: Set<TrackedPermission>
    public let trigger: PermissionCheckTrigger

    /// Monitors all available permission types, triggered on foreground.
    public static let all = PermissionTrackConfig()

    public init(
        permissions: Set<TrackedPermission> = Set(TrackedPermission.allCases),
        trigger: PermissionCheckTrigger = .willEnterForeground
    ) {
        self.permissions = permissions
        self.trigger = trigger
    }
}

public struct AutoTrackConfig: Sendable {
    public let appLifecycle: Bool
    /// Controls screen-view tracking. Pass `nil` to disable both automatic UIKit
    /// screen tracking and SwiftUI `.trackScreen(_:)` calls.
    ///
    /// Both UIKit and SwiftUI screen names are filtered through the same
    /// `ScreenTrackingConfig` rules.
    public let screenViews: ScreenTrackingConfig?
    public let taps: Bool
    public let apiCalls: Bool
    public let crashes: Bool
    public let connectivity: Bool
    public let deepLinks: Bool
    public let deviceSnapshot: Bool
    public let memoryPressure: Bool
    public let batteryThermal: Bool
    public let permissionChanges: PermissionTrackConfig?
    public let pushNotifications: Bool
    public let webViews: Bool
    public let backgroundTasks: Bool
    public let preferenceChanges: Bool

    public init(
        appLifecycle: Bool = true,
        screenViews: ScreenTrackingConfig? = ScreenTrackingConfig(),
        taps: Bool = true,
        apiCalls: Bool = true,
        crashes: Bool = true,
        connectivity: Bool = true,
        deepLinks: Bool = true,
        deviceSnapshot: Bool = true,
        memoryPressure: Bool = true,
        batteryThermal: Bool = true,
        permissionChanges: PermissionTrackConfig? = nil,
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

/// Unified screen tracking configuration. Both UIKit (`viewDidAppear` swizzle)
/// and SwiftUI (`.trackScreen` modifier) filter through the same shared rules.
public struct ScreenTrackingConfig: Sendable {

    // MARK: - Shared filtering (UIKit + SwiftUI)

    /// Screen names matching any of these prefixes are silently ignored.
    public let ignoredScreenPrefixes: [String]

    /// When non-empty, only screen names matching at least one prefix are tracked.
    /// An empty array means "allow all" (subject to `ignoredScreenPrefixes`).
    public let allowedScreenPrefixes: [String]

    /// Final predicate after prefix checks. Return `false` to suppress the event.
    public let shouldTrackScreen: (@Sendable (String) -> Bool)?

    // MARK: - UIKit infrastructure controller suppression

    /// Exact UIKit controller class names to skip before naming.
    /// Only applies to the `viewDidAppear` swizzle path.
    public let ignoredControllerNames: Set<String>

    /// UIKit controller class-name prefixes to skip before naming.
    /// Only applies to the `viewDidAppear` swizzle path.
    public let ignoredControllerNamePrefixes: [String]

    // MARK: - UIKit naming strategy

    /// How the UIKit swizzle derives a screen name from a UIViewController.
    public let uikitNaming: UIKitScreenNaming

    public enum UIKitScreenNaming: Sendable {
        /// Use `String(describing: type(of: viewController))`.
        case className
        /// Use `viewController.view.accessibilityIdentifier`. Missing identifier = skip.
        case accessibilityIdentifier
    }

    // MARK: - Defaults

    public static let defaultIgnoredControllerNames: Set<String> = [
        "UIAlertController",
        "UICompatibilityInputViewController",
        "UIInputViewController",
        "UINavigationController",
        "UIPageViewController",
        "UISplitViewController",
        "UISystemInputAssistantViewController",
        "UITabBarController",
        "UIHostingController",
        "TabHostingController"
    ]

    public static let defaultIgnoredControllerNamePrefixes: [String] = [
        "_",
        "SwiftUI.",
        "UIHostingController<",
        "NavigationStackHostingController<",
        "PresentationHostingController<",
        "TabHostingController<",
        "UIKitTabBarController",
        "UIKitNavigationController"
    ]

    public init(
        ignoredScreenPrefixes: [String] = [],
        allowedScreenPrefixes: [String] = [],
        shouldTrackScreen: (@Sendable (String) -> Bool)? = nil,
        ignoredControllerNames: Set<String> = ScreenTrackingConfig.defaultIgnoredControllerNames,
        ignoredControllerNamePrefixes: [String] = ScreenTrackingConfig.defaultIgnoredControllerNamePrefixes,
        uikitNaming: UIKitScreenNaming = .className
    ) {
        self.ignoredScreenPrefixes = ignoredScreenPrefixes
        self.allowedScreenPrefixes = allowedScreenPrefixes
        self.shouldTrackScreen = shouldTrackScreen
        self.ignoredControllerNames = ignoredControllerNames
        self.ignoredControllerNamePrefixes = ignoredControllerNamePrefixes
        self.uikitNaming = uikitNaming
    }

    /// Determines whether a screen name (from any source) should emit an event.
    func shouldTrack(screenName name: String) -> Bool {
        guard !name.isEmpty else { return false }

        if ignoredScreenPrefixes.contains(where: { name.hasPrefix($0) }) {
            return false
        }

        if !allowedScreenPrefixes.isEmpty {
            guard allowedScreenPrefixes.contains(where: { name.hasPrefix($0) }) else {
                return false
            }
        }

        if let shouldTrackScreen {
            return shouldTrackScreen(name)
        }

        return true
    }

    /// UIKit-only: checks if a controller class name is an infrastructure
    /// container that should be skipped before screen name derivation.
    func shouldSkipController(name: String) -> Bool {
        if ignoredControllerNames.contains(name) { return true }
        if ignoredControllerNamePrefixes.contains(where: { name.hasPrefix($0) }) { return true }
        return false
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
