import Foundation
#if os(iOS)
import UIKit

/// Records battery level/state changes and thermal state changes.
///
/// Observes `UIDevice.batteryStateDidChangeNotification`,
/// `UIDevice.batteryLevelDidChangeNotification`, and
/// `ProcessInfo.thermalStateDidChangeNotification`.
/// `isBatteryMonitoringEnabled` is enabled/disabled symmetrically in start/stop.
final class BatteryTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    init(runtime: AppDiagLogRuntime) {
        self.runtime = runtime
    }

    func start() async {
        await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = true }

        let center = NotificationCenter.default
        let batteryStateToken = center.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleBattery()
            }
        }

        let batteryLevelToken = center.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleBattery()
            }
        }

        let thermalToken = center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.handleThermal() }

        setTokens([batteryStateToken, batteryLevelToken, thermalToken])
    }

    func stop() async {
        let drained = drainTokens()
        for token in drained {
            NotificationCenter.default.removeObserver(token)
        }
        await MainActor.run { UIDevice.current.isBatteryMonitoringEnabled = false }
    }

    // MARK: - Lock helpers

    private func setTokens(_ newTokens: [NSObjectProtocol]) {
        lock.lock(); defer { lock.unlock() }
        tokens = newTokens
    }

    private func drainTokens() -> [NSObjectProtocol] {
        lock.lock(); defer { lock.unlock() }
        let t = tokens
        tokens.removeAll()
        return t
    }

    // MARK: - Handlers (called on main queue)

    @MainActor private func handleBattery() {
        let device = UIDevice.current
        let levelValue = device.batteryLevel
        let level = levelValue >= 0 ? String(Int(levelValue * 100)) : "-1"

        let state: String
        switch device.batteryState {
        case .charging:   state = "charging"
        case .full:       state = "full"
        case .unplugged:  state = "unplugged"
        default:          state = "unknown"
        }

        let runtime = self.runtime
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.battery,
                level: .info,
                props: ["level_pct": level, "state": state]
            )
        }
    }

    private func handleThermal() {
        let thermalState = ProcessInfo.processInfo.thermalState
        let state: String
        switch thermalState {
        case .nominal:  state = "nominal"
        case .fair:     state = "fair"
        case .serious:  state = "serious"
        case .critical: state = "critical"
        @unknown default: state = "unknown"
        }

        let eventLevel: LogLevel = thermalState == .critical ? .error
                                 : thermalState == .serious  ? .warning
                                 : .info

        let runtime = self.runtime
        Task.detached(priority: .utility) {
            await runtime.pipeline.enqueue(
                event: EventName.thermal,
                level: eventLevel,
                props: ["state": state]
            )
        }
    }
}
#endif
