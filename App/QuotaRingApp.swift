import SwiftUI

@main
struct QuotaRingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Text("Settings")
                .frame(width: 320, height: 160)
        }
    }
}
