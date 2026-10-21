import AppKit
import QuotaRingCore
import SwiftUI

/// Which usage levels and events notify, and whether macOS allows QuotaRing to show notifications.
struct NotificationSettingsView: View {
    @Bindable var settings: SettingsStore
    let notifications: NotificationService
    @State private var permission: NotificationPermission?
    /// A fixed permission for previews and screenshots; `nil` reads the real one from macOS.
    private let previewPermission: NotificationPermission?

    init(settings: SettingsStore, notifications: NotificationService, previewPermission: NotificationPermission? = nil)
    {
        self.settings = settings
        self.notifications = notifications
        self.previewPermission = previewPermission
        _permission = State(initialValue: previewPermission)
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: thresholdBinding(80)) {
                    Text("When 5-hour usage reaches \(QuotaFormat.percent(80))")
                }
                Toggle(isOn: thresholdBinding(95)) {
                    Text("When 5-hour usage reaches \(QuotaFormat.percent(95))")
                }
                Toggle("Notify when the session resets", isOn: resetBinding)
            } footer: {
                Text("Each notification appears once per 5-hour session. Everything stays on this Mac.")
            }

            if needsPermissionNote {
                Section {
                    permissionNote
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            if previewPermission == nil { await refreshPermission() }
        }
        // The user may change the permission in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshPermission() }
        }
    }

    // MARK: - Settings bindings

    private var anyNotificationEnabled: Bool {
        !settings.notificationThresholds.isEmpty || settings.notifyOnReset
    }

    private func thresholdBinding(_ threshold: Int) -> Binding<Bool> {
        Binding(
            get: { settings.notificationThresholds.contains(threshold) },
            set: { enabled in
                var thresholds = Set(settings.notificationThresholds)
                if enabled {
                    thresholds.insert(threshold)
                } else {
                    thresholds.remove(threshold)
                }
                settings.notificationThresholds = thresholds.sorted()
                if enabled { askForPermission() }
            }
        )
    }

    private var resetBinding: Binding<Bool> {
        Binding(
            get: { settings.notifyOnReset },
            set: { enabled in
                settings.notifyOnReset = enabled
                if enabled { askForPermission() }
            }
        )
    }

    // MARK: - Permission

    private var needsPermissionNote: Bool {
        switch permission {
        case .denied: true
        case .notDetermined: anyNotificationEnabled
        case .allowed, nil: false
        }
    }

    @ViewBuilder
    private var permissionNote: some View {
        switch permission {
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications are turned off for QuotaRing in System Settings.", systemImage: "bell.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Notification Settings…", action: notifications.openSystemSettings)
            }
        case .notDetermined where anyNotificationEnabled:
            VStack(alignment: .leading, spacing: 6) {
                Label("macOS has not been asked to allow notifications from QuotaRing yet.", systemImage: "bell")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Notifications…", action: askForPermission)
            }
        case .notDetermined, .allowed, nil:
            EmptyView()
        }
    }

    /// Shows the system prompt (only if macOS has not asked yet), then updates the note.
    private func askForPermission() {
        Task { permission = await notifications.requestAuthorizationIfNeeded() }
    }

    private func refreshPermission() async {
        permission = await notifications.permission()
    }
}
