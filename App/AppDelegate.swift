import AppKit

/// Creates the app's state and the menu bar item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether the app was launched with `--demo` (fixture data only).
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    /// Created on first use, so SwiftUI scenes may reference them before the app has finished launching.
    lazy var settings = SettingsStore()
    lazy var model = AppModel(settings: settings, isDemo: isDemo)

    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController(model: model)
        // Install `model.notifier` before this line so the first snapshot can already notify.
        model.start()
    }
}
