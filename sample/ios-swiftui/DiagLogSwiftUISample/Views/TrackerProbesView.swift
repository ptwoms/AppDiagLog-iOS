import SwiftUI
import AppDiagLog
import UIKit

struct TrackerProbesView: View {
    @State private var deviceInfo = DeviceProbeInfo.current
    @State private var batteryInfo = BatteryProbeInfo.current
    @State private var memInfo = MemProbeInfo.current
    @State private var prefKey = "sample_pref_key"
    @State private var prefValue = "hello_appdiaglog"
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
                    Text("Write a UserDefaults key-value pair and emit a manual preference_change event. The SDK's PreferenceChangeTracker observes UserDefaults.didChangeNotification automatically when enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("Key", text: $prefKey)
                        .autocorrectionDisabled()
                    TextField("Value", text: $prefValue)
                        .autocorrectionDisabled()

                    Button {
                        UserDefaults.standard.set(prefValue, forKey: prefKey)
                        AppDiagLog.info("preference_change_manual", [
                            "key": prefKey,
                            "value": prefValue,
                            "source": "tracker_probes",
                        ])
                        appendAction("Wrote \(prefKey)=\(prefValue) and logged preference_change_manual.")
                    } label: {
                        Label("Write Preference & Log Event", systemImage: "slider.horizontal.3")
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
