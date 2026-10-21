import SwiftUI

@main
struct QuotaRingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model, notifications: appDelegate.notificationService)
        }
    }
}
