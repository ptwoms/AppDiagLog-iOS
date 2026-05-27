import SwiftUI
import AppDiagLog
import UIKit
import UserNotifications

struct TrackerProbesView: View {
    @State private var deviceInfo = DeviceProbeInfo.current
    @State private var batteryInfo = BatteryProbeInfo.current
    @State private var memInfo = MemProbeInfo.current
    @State private var prefKey = "sample_pref_key"
    @State private var prefValue = "hello_appdiaglog"
    @State private var currentPrefValue: String = UserDefaults.standard.string(forKey: "sample_pref_key") ?? "—"
    @State private var pushCategory = "order_update"
    @State private var webURLString = "https://example.com/products/123"
    @State private var bgTaskId = "com.example.sync"
    @State private var actionLog = [LogEntry("Tap any section to emit a manual probe event.")]

    var body: some View {
        NavigationStack {
            List {
                Section("Device Snapshot") {
                    Text("The SDK captures these fields automatically at session start via DeviceSnapshot.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    infoRow("OS", deviceInfo.os)
                    infoRow("Model", deviceInfo.model)
                    infoRow("Locale", deviceInfo.locale)
                    infoRow("Timezone", deviceInfo.timezone)

                    Button {
                        deviceInfo = DeviceProbeInfo.current
                        AppDiagLog.info("device_snapshot_manual", [
                            "os": deviceInfo.os,
                            "model": deviceInfo.model,
                            "locale": deviceInfo.locale,
                            "timezone": deviceInfo.timezone,
                            "source": "tracker_probes",
                        ])
                        appendAction("Logged device_snapshot_manual.")
                    } label: {
                        Label("Refresh & Log Device Snapshot", systemImage: "iphone")
                    }
                }

                Section("Battery & Thermal") {
                    Text("The SDK's BatteryTracker observes UIDevice battery state and ProcessInfo thermal state automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    infoRow("Level", batteryInfo.level)
                    infoRow("State", batteryInfo.state)
                    infoRow("Thermal", batteryInfo.thermal)

                    Button {
                        batteryInfo = BatteryProbeInfo.current
                        AppDiagLog.info("battery_check_manual", [
                            "level": batteryInfo.level,
                            "state": batteryInfo.state,
                            "thermal": batteryInfo.thermal,
                            "source": "tracker_probes",
                        ])
                        appendAction("Logged battery_check_manual level=\(batteryInfo.level).")
                    } label: {
                        Label("Refresh & Log Battery State", systemImage: "battery.75percent")
                    }
                }

                Section("Memory") {
                    Text("Use Xcode > Debug > Simulate Memory Warning to trigger a real didReceiveMemoryWarning event. The SDK logs memory_pressure automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    infoRow("Physical RAM", memInfo.physicalRam)
                    infoRow("App footprint", memInfo.footprint)

                    Button {
                        memInfo = MemProbeInfo.current
                        AppDiagLog.warning("memory_check_manual", [
                            "physical_ram": memInfo.physicalRam,
                            "footprint": memInfo.footprint,
                            "source": "tracker_probes",
                        ])
                        appendAction("Logged memory_check_manual footprint=\(memInfo.footprint).")
                    } label: {
                        Label("Refresh & Log Memory State", systemImage: "memorychip")
                    }
                }

                Section("Preferences") {
                    Text("Write a UserDefaults key-value pair. PreferenceChangeTracker observes UserDefaults.didChangeNotification automatically — no manual log call needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Key", text: $prefKey)
                        .autocorrectionDisabled()
                    TextField("New Value", text: $prefValue)
                        .autocorrectionDisabled()

                    LabeledContent("Current Value") {
                        Text(currentPrefValue)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    Button {
                        UserDefaults.standard.set(prefValue, forKey: prefKey)
                        currentPrefValue = prefValue
                        appendAction("Wrote \(prefKey)=\(prefValue). PreferenceChangeTracker fires automatically.")
                    } label: {
                        Label("Write Preference", systemImage: "slider.horizontal.3")
                    }
                }

                Section("Push Notifications") {
                    Text("Schedule a real local notification with action buttons. The app's UNUserNotificationCenterDelegate calls AppDiagLog.trackPushReceived / trackPushInteraction automatically — no manual SDK call needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Category ID", text: $pushCategory)
                        .autocorrectionDisabled()

                    Text("Actions registered for \"order_update\": View Order, Dismiss.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        Task {
                            await scheduleTestNotification()
                        }
                    } label: {
                        Label("Schedule Test Notification (5 s)", systemImage: "bell.badge.clock")
                    }

                    Text("Background the app after tapping — the notification appears in 5 seconds with action buttons.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("WebView Navigation") {
                    Text("Use DiagLogNavigationDelegate as your WKWebView delegate for automatic tracking, or call AppDiagLog.trackWebNavigation manually.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("URL", text: $webURLString)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    Button {
                        if let url = URL(string: webURLString) {
                            AppDiagLog.trackWebNavigation(url: url, event: "did_start")
                            appendAction("Web nav did_start — \(webURLString).")
                        }
                    } label: {
                        Label("Simulate Navigation Start", systemImage: "globe")
                    }

                    Button {
                        if let url = URL(string: webURLString) {
                            AppDiagLog.trackWebNavigation(url: url, event: "did_finish")
                            appendAction("Web nav did_finish — \(webURLString).")
                        }
                    } label: {
                        Label("Simulate Navigation Finish", systemImage: "checkmark.circle")
                    }
                }

                Section("Background Tasks") {
                    Text("Call AppDiagLog.trackBackgroundTask from your BGTask handler (begin, expired, completed). Use these buttons to simulate events.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Task identifier", text: $bgTaskId)
                        .autocorrectionDisabled()

                    HStack {
                        Button("Begin") {
                            AppDiagLog.trackBackgroundTask(identifier: bgTaskId, event: "begin")
                            appendAction("BG task begin — \(bgTaskId).")
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        Button("Expired") {
                            AppDiagLog.trackBackgroundTask(identifier: bgTaskId, event: "expired")
                            appendAction("BG task expired — \(bgTaskId).")
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        Spacer()
                        Button("Completed") {
                            AppDiagLog.trackBackgroundTask(identifier: bgTaskId, event: "completed")
                            appendAction("BG task completed — \(bgTaskId).")
                        }
                        .buttonStyle(.bordered)
                        .tint(.green)
                    }
                }

                Section("Recent Actions") {
                    ForEach(actionLog) { action in
                        Text(action.message)
                            .font(.footnote.monospaced())
                    }
                }
            }
            .navigationTitle("Tracker Probes")
        }
        .trackScreen("TrackerProbesView")
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryInfo = BatteryProbeInfo.current
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
            batteryInfo = BatteryProbeInfo.current
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            batteryInfo = BatteryProbeInfo.current
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            currentPrefValue = UserDefaults.standard.string(forKey: prefKey) ?? "—"
        }
    }

    private func scheduleTestNotification() async {
        let notifCenter = UNUserNotificationCenter.current()
        let settings = await notifCenter.notificationSettings()
        guard settings.authorizationStatus == .authorized ||
                settings.authorizationStatus == .provisional else {
            appendAction("Push not authorized. Visit the Permissions screen first.")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "AppDiagLog Sample"
        content.body = "Tap an action to test push interaction tracking."
        content.sound = .default
        content.categoryIdentifier = pushCategory
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: trigger
        )
        do {
            try await notifCenter.add(request)
            appendAction("Notification scheduled — fires in 5 s. Background the app now.")
        } catch {
            appendAction("Failed to schedule: \(error.localizedDescription)")
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func appendAction(_ message: String) {
        actionLog.append(message)
    }
}

// MARK: - Data helpers

private struct DeviceProbeInfo {
    let os: String
    let model: String
    let locale: String
    let timezone: String

    @MainActor static var current: DeviceProbeInfo {
        let device = UIDevice.current
        return DeviceProbeInfo(
            os: "\(device.systemName) \(device.systemVersion)",
            model: device.model,
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier
        )
    }
}

private struct BatteryProbeInfo {
    let level: String
    let state: String
    let thermal: String

    @MainActor static var current: BatteryProbeInfo {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let levelValue = UIDevice.current.batteryLevel
        let levelStr = levelValue >= 0 ? "\(Int(levelValue * 100))%" : "Unknown"

        let stateStr: String
        switch UIDevice.current.batteryState {
        case .charging: stateStr = "Charging"
        case .full: stateStr = "Full"
        case .unplugged: stateStr = "Unplugged"
        default: stateStr = "Unknown"
        }

        let thermalStr: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalStr = "Nominal"
        case .fair: thermalStr = "Fair"
        case .serious: thermalStr = "Serious"
        case .critical: thermalStr = "Critical"
        @unknown default: thermalStr = "Unknown"
        }

        return BatteryProbeInfo(level: levelStr, state: stateStr, thermal: thermalStr)
    }
}

private struct MemProbeInfo {
    let physicalRam: String
    let footprint: String

    static var current: MemProbeInfo {
        let totalMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        var footprintMB: UInt64 = 0
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info>.size / MemoryLayout<integer_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            footprintMB = info.phys_footprint / (1024 * 1024)
        }
        return MemProbeInfo(
            physicalRam: "\(totalMB) MB",
            footprint: footprintMB > 0 ? "\(footprintMB) MB" : "Unavailable"
        )
    }
}
