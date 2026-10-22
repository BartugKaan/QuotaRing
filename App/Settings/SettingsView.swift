import SwiftUI

/// The tabs of the Settings window.
enum SettingsTab: Hashable {
    case general, notifications, data, about
}

/// The Settings window: General, Notifications, Data and About.
struct SettingsView: View {
    @Bindable var model: AppModel
    let notifications: NotificationService

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettingsView(settings: model.settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            NotificationSettingsView(settings: model.settings, notifications: notifications)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)
            DataSettingsView(settings: model.settings, model: model)
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag(SettingsTab.data)
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 480)
    }
}
