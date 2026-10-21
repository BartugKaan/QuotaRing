import SwiftUI

/// The Settings window: General, Notifications, Data and About.
struct SettingsView: View {
    let model: AppModel
    let notifications: NotificationService

    var body: some View {
        TabView {
            GeneralSettingsView(settings: model.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            NotificationSettingsView(settings: model.settings, notifications: notifications)
                .tabItem { Label("Notifications", systemImage: "bell") }
            DataSettingsView(settings: model.settings, isDemo: model.isDemo)
                .tabItem { Label("Data", systemImage: "externaldrive") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
    }
}
