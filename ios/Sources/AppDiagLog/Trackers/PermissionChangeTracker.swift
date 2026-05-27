import Foundation
#if os(iOS)
import AVFoundation
import CoreLocation
import CoreMotion
import Contacts
import EventKit
import Photos
import Speech
import AppTrackingTransparency
import UserNotifications
import UIKit

/// Snapshots authorization statuses and emits events for permission changes.
///
/// At launch: logs and records all current permission statuses as `permission_snapshot`
/// events. This covers the case where iOS restarts the app after a sensitive permission
/// (Camera, Photos) is granted from Settings — there is no foreground notification in
/// that path, so comparing the launch snapshot to a persisted one would be fragile.
/// Logging everything at start gives a clear before/after picture across sessions.
///
/// On each foreground transition: diffs the new snapshot against the previous one and
/// emits a `permission_change` event only for statuses that actually changed.
///
/// Which permissions are monitored is controlled by `PermissionTrackConfig`.
final class PermissionChangeTracker: Tracker, @unchecked Sendable {
    private let runtime: AppDiagLogRuntime
    private let config: PermissionTrackConfig
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private var previousSnapshot: [String: String] = [:]

    init(runtime: AppDiagLogRuntime, config: PermissionTrackConfig) {
        self.runtime = runtime
        self.config = config
    }

    func start() async {
        let snapshot = await captureSnapshot()
        setSnapshot(snapshot)
        await emitSnapshot(snapshot)

        let notifName: Notification.Name = switch config.trigger {
        case .willEnterForeground: UIApplication.willEnterForegroundNotification
        case .didBecomeActive: UIApplication.didBecomeActiveNotification
        }

        let t = NotificationCenter.default.addObserver(
            forName: notifName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForChanges()
        }
        setToken(t)
    }

    func stop() async {
        if let t = takeToken() {
            NotificationCenter.default.removeObserver(t)
        }
    }

    // MARK: - Sync lock helpers

    private func setToken(_ t: NSObjectProtocol) {
        lock.lock(); defer { lock.unlock() }
        token = t
    }

    private func takeToken() -> NSObjectProtocol? {
        lock.lock(); defer { lock.unlock() }
        let t = token; token = nil; return t
    }

    private func setSnapshot(_ s: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        previousSnapshot = s
    }

    private func swapSnapshot(_ s: [String: String]) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let old = previousSnapshot; previousSnapshot = s; return old
    }

    // MARK: - Emit helpers

    /// Logs and records every permission status in `snapshot` as a single
    /// `permission_snapshot` event. Called once at launch so the session always
    /// contains a baseline, including after iOS restarts the app.
    private func emitSnapshot(_ snapshot: [String: String]) async {
        let sorted = snapshot.sorted { $0.key < $1.key }
        let summary = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        SdkLog.info("permission snapshot at launch: \(summary)")
        await runtime.pipeline.enqueue(
            event: EventName.permissionSnapshot,
            level: .info,
            props: snapshot
        )
    }

    // MARK: - Diff and emit

    private func checkForChanges() {
        let runtime = self.runtime
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let newSnapshot = await self.captureSnapshot()
            let oldSnapshot = self.swapSnapshot(newSnapshot)
            for (permission, status) in newSnapshot {
                guard oldSnapshot[permission] != status else { continue }
                SdkLog.info("permission '\(permission)' changed: \(oldSnapshot[permission] ?? "nil") → \(status)")
                await runtime.pipeline.enqueue(
                    event: EventName.permissionChange,
                    level: .info,
                    props: ["permission": permission, "status": status]
                )
            }
        }
    }

    // MARK: - Snapshot capture

    private func captureSnapshot() async -> [String: String] {
        var snapshot: [String: String] = [:]
        let perms = config.permissions

        if perms.contains(.camera) {
            snapshot["camera"] = avStatus(AVCaptureDevice.authorizationStatus(for: .video))
        }
        if perms.contains(.microphone) {
            snapshot["microphone"] = avStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        }
        if perms.contains(.photos) {
            snapshot["photos"] = photoStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
        if perms.contains(.location) {
            let locationAuthStatus = await MainActor.run { CLLocationManager().authorizationStatus }
            snapshot["location"] = clStatus(locationAuthStatus)
        }
        if perms.contains(.notifications) {
            let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
            let statusAndType = notifStatusAndType(notifSettings)
            snapshot["notifications"] = statusAndType.status
            snapshot["notifications_types"] = statusAndType.types
        }
        if perms.contains(.contacts) {
            snapshot["contacts"] = cnStatus(CNContactStore.authorizationStatus(for: .contacts))
        }
        if perms.contains(.calendar) {
            snapshot["calendar"] = ekStatus(EKEventStore.authorizationStatus(for: .event))
        }
        if perms.contains(.reminders) {
            snapshot["reminders"] = ekStatus(EKEventStore.authorizationStatus(for: .reminder))
        }
        if perms.contains(.speechRecognition) {
            snapshot["speech_recognition"] = speechStatus(SFSpeechRecognizer.authorizationStatus())
        }
        if perms.contains(.motionFitness) {
            snapshot["motion_fitness"] = motionStatus(CMMotionActivityManager.authorizationStatus())
        }
        if perms.contains(.appTracking) {
            snapshot["app_tracking"] = attStatus(ATTrackingManager.trackingAuthorizationStatus)
        }

        return snapshot
    }

    // MARK: - Status string helpers

    private func avStatus(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func photoStatus(_ s: PHAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func clStatus(_ s: CLAuthorizationStatus) -> String {
        switch s {
        case .authorizedAlways: return "authorized_always"
        case .authorizedWhenInUse: return "authorized_when_in_use"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func cnStatus(_ s: CNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func ekStatus(_ s: EKAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func speechStatus(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func motionStatus(_ s: CMAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func attStatus(_ s: ATTrackingManager.AuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }

    private func notifStatusAndType(_ notifSetting: UNNotificationSettings) -> (status: String, types: String?) {
        let notifStatus = switch notifSetting.authorizationStatus {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "not_determined"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }

        let typeChecks: [(UNNotificationSetting, String)] = [
            (notifSetting.alertSetting, "alert"),
            (notifSetting.soundSetting, "sound"),
            (notifSetting.badgeSetting, "badge"),
            (notifSetting.lockScreenSetting, "lock_screen"),
            (notifSetting.notificationCenterSetting, "notification_center"),
            (notifSetting.carPlaySetting, "car_play"),
            (notifSetting.criticalAlertSetting, "critical_alert"),
            (notifSetting.announcementSetting, "announcement"),
            (notifSetting.timeSensitiveSetting, "time_sensitive"),
            (notifSetting.scheduledDeliverySetting, "scheduled_delivery"),
            (notifSetting.directMessagesSetting, "direct_messages")
        ]
        let enabledTypes = typeChecks
            .filter { $0.0 == .enabled }
            .map(\.1)
            .joined(separator: ",")

        return (notifStatus, enabledTypes.isEmpty ? nil : enabledTypes)
    }
}
#endif
