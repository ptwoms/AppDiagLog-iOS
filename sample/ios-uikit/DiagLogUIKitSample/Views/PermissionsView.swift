import SwiftUI
import AVFoundation
import Photos
import Contacts
import UserNotifications
import UIKit
import AppDiagLog

struct PermissionsView: View {
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var pushStatus: UNAuthorizationStatus = .notDetermined
    @State private var actionLog = [LogEntry("Permission changes are tracked automatically by PermissionChangeTracker.")]

    var body: some View {
        List {
            Section {
                Text("Granting or denying each permission triggers a permission_change event via PermissionChangeTracker. The SDK polls authorization status on app foreground transitions.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            cameraSection
            photoSection
            contactsSection
            pushSection

            Section("Recent Events") {
                ForEach(actionLog) { entry in
                    Text(entry.message)
                        .font(.footnote.monospaced())
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear { refreshAllStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshAllStatuses()
        }
    }

    // MARK: - Sections

    private var cameraSection: some View {
        Section("Camera") {
            statusRow(icon: "camera.fill", title: "Camera", label: cameraLabel, tint: cameraTint)
            switch cameraStatus {
            case .notDetermined:
                Button { requestCamera() } label: {
                    Label("Request Camera Access", systemImage: "hand.raised")
                }
            case .denied, .restricted:
                Button { openSettings() } label: {
                    Label("Open Settings to Enable Camera", systemImage: "gear.badge.xmark")
                }
                .foregroundColor(.orange)
            case .authorized:
                Label("Access Granted", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            @unknown default:
                EmptyView()
            }
        }
    }

    private var photoSection: some View {
        Section("Photo Library") {
            statusRow(icon: "photo.on.rectangle.fill", title: "Photos", label: photoLabel, tint: photoTint)
            switch photoStatus {
            case .notDetermined:
                Button { requestPhotos() } label: {
                    Label("Request Photo Library Access", systemImage: "hand.raised")
                }
            case .denied, .restricted:
                Button { openSettings() } label: {
                    Label("Open Settings to Enable Photos", systemImage: "gear.badge.xmark")
                }
                .foregroundColor(.orange)
            case .authorized, .limited:
                Label(photoStatus == .limited ? "Limited Access Granted" : "Full Access Granted", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            @unknown default:
                EmptyView()
            }
        }
    }

    private var contactsSection: some View {
        Section("Contacts") {
            statusRow(icon: "person.crop.circle.fill", title: "Contacts", label: contactsLabel, tint: contactsTint)
            switch contactsStatus {
            case .notDetermined:
                Button { requestContacts() } label: {
                    Label("Request Contacts Access", systemImage: "hand.raised")
                }
            case .denied, .restricted:
                Button { openSettings() } label: {
                    Label("Open Settings to Enable Contacts", systemImage: "gear.badge.xmark")
                }
                .foregroundColor(.orange)
            case .authorized:
                Label("Access Granted", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            default:
                EmptyView()
            }
        }
    }

    private var pushSection: some View {
        Section("Push Notifications") {
            statusRow(icon: "bell.badge.fill", title: "Notifications", label: pushLabel, tint: pushTint)
            switch pushStatus {
            case .notDetermined:
                Button { requestPushNotifications() } label: {
                    Label("Request Notification Permission", systemImage: "bell")
                }
            case .denied:
                Text("The system prompt can only appear once. Redirect to Settings to re-enable.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button { openSettings() } label: {
                    Label("Open Settings to Enable Notifications", systemImage: "gear.badge.xmark")
                }
                .foregroundColor(.orange)
            case .authorized, .provisional, .ephemeral:
                Label("Notifications Enabled", systemImage: "checkmark.seal.fill")
                    .foregroundColor(.green)
            @unknown default:
                Button { openSettings() } label: {
                    Label("Open Settings", systemImage: "gear")
                }
            }
        }
    }

    // MARK: - Helpers

    private func statusRow(icon: String, title: String, label: String, tint: Color) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text(label)
                .font(.footnote)
                .foregroundColor(tint)
        }
    }

    // MARK: - Status labels / tints

    private var cameraLabel: String {
        switch cameraStatus {
        case .notDetermined: return "Not Asked"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Granted"
        @unknown default: return "Unknown"
        }
    }
    private var cameraTint: Color {
        switch cameraStatus {
        case .authorized: return .green
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    private var photoLabel: String {
        switch photoStatus {
        case .notDetermined: return "Not Asked"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Full Access"
        case .limited: return "Limited"
        @unknown default: return "Unknown"
        }
    }
    private var photoTint: Color {
        switch photoStatus {
        case .authorized, .limited: return .green
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    private var contactsLabel: String {
        switch contactsStatus {
        case .notDetermined: return "Not Asked"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Granted"
        case .limited: return "Limited"
        @unknown default: return "Unknown"
        }
    }
    private var contactsTint: Color {
        switch contactsStatus {
        case .authorized: return .green
        case .denied, .restricted: return .red
        default: return .secondary
        }
    }

    private var pushLabel: String {
        switch pushStatus {
        case .notDetermined: return "Not Asked"
        case .denied: return "Denied"
        case .authorized: return "Granted"
        case .provisional: return "Provisional"
        case .ephemeral: return "Ephemeral"
        @unknown default: return "Unknown"
        }
    }
    private var pushTint: Color {
        switch pushStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    // MARK: - Permission Requests

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor in
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                appendAction("Camera: \(granted ? "granted" : "denied").")
            }
        }
    }

    private func requestPhotos() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            Task { @MainActor in
                photoStatus = status
                appendAction("Photos: \(photoLabel).")
            }
        }
    }

    private func requestContacts() {
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
            Task { @MainActor in
                contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
                appendAction("Contacts: \(granted ? "granted" : "denied").")
            }
        }
    }

    private func requestPushNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            Task { @MainActor in
                refreshAllStatuses()
                appendAction("Push: \(granted ? "granted" : "denied").")
            }
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func refreshAllStatuses() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        photoStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorizationStatus = settings.authorizationStatus
            Task { @MainActor in
                pushStatus = authorizationStatus
            }
        }
    }

    private func appendAction(_ message: String) {
        actionLog.append(message)
    }
}
