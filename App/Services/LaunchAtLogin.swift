import ServiceManagement

/// Starting QuotaRing when the user logs in, through `SMAppService.mainApp` (a login item the user can also manage in
/// System Settings → General → Login Items).
enum LaunchAtLogin {
    /// The login item's current state, read from the system each time (the user can change it outside the app).
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Whether the app will start at login.
    static var isEnabled: Bool {
        status == .enabled
    }

    /// Whether the login item is registered, including the case where macOS still waits for the user's approval.
    static var isRegistered: Bool {
        isRegistered(status)
    }

    static func isRegistered(_ status: SMAppService.Status) -> Bool {
        switch status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        @unknown default: false
        }
    }

    /// Registers or unregisters the login item. Throws what `SMAppService` throws.
    static func set(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else if isRegistered(service.status) {
            try service.unregister()
        }
    }

    /// Opens System Settings → General → Login Items, where the user approves or removes the login item.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
