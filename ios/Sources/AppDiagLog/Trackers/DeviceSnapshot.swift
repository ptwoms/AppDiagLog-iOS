import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Captures plaintext device metadata stored in the envelope header so support can triage
/// sessions before requesting a decryption key.
///
/// None of this is PII. We intentionally exclude: IDFA, IDFV, account identifiers,
/// and anything that requires extra entitlements (e.g. DeviceCheck).
enum DeviceSnapshot {
    /// Returns an ordered dictionary-shaped `[String: String]`. Values are Strings only —
    /// matches the event `props` schema and keeps serialization trivial.
    static func capture() async -> [String: String] {
        var map: [String: String] = [:]
        map.reserveCapacity(16)

        #if os(iOS) || os(tvOS)
        await MainActor.run {
            let curDevice = UIDevice.current
            map["os"] = "iOS \(curDevice.systemVersion)"
            map["model"] = curDevice.model
            map["night_mode"] = (UITraitCollection.current.userInterfaceStyle == .dark) ? "yes" : "no"
        }
        map["device"] = deviceIdentifier()
        #elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        map["os"] = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        map["device"] = deviceIdentifier()
        #else
        map["os"] = "unknown"
        #endif

        map["app_package"] = Bundle.main.bundleIdentifier ?? "unknown"
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            map["app_version"] = v
        }
        if let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            map["app_version_code"] = b
        }

        map["locale"] = Locale.current.identifier
        map["timezone"] = TimeZone.current.identifier
        map["sdk_version"] = AppDiagLog.sdkVersion

        // Free disk
        if let freeBytes = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        {
            map["disk_free_mb"] = String(freeBytes / 1_000_000)
        }

        // Low-power mode (a meaningful triage signal — battery stalls and network throttling)
        map["low_power_mode"] = ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no"

        // Thermal state
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: map["thermal_state"] = "nominal"
        case .fair: map["thermal_state"] = "fair"
        case .serious: map["thermal_state"] = "serious"
        case .critical: map["thermal_state"] = "critical"
        @unknown default: map["thermal_state"] = "unknown"
        }

        return map
    }

    /// Hardware identifier, e.g. "iPhone16,2". Safe — non-personal, the same string every
    /// iPhone 15 Pro Max ships with.
    private static func deviceIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        var id = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { continue }
            id.append(Character(UnicodeScalar(UInt8(value))))
        }
        return id.isEmpty ? "unknown" : id
    }
}
