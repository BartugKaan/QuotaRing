import AppKit

/// Creates the app's state and the menu bar item.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Whether the app was launched with `--demo` (fixture data only).
    let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    /// Created on first use, so SwiftUI scenes may reference them before the app has finished launching.
    lazy var settings = SettingsStore()
    lazy var model = AppModel(settings: settings, isDemo: isDemo)
    /// Demo mode never shows the real notification permission prompt.
    lazy var notificationService = NotificationService(allowsPermissionRequests: !isDemo)

    private var statusItemController: StatusItemController?
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before `model.start()`, so the first snapshot can already notify.
        model.notifier = notificationService
        model.showWelcomeWindow = { [weak self] in self?.showOnboardingIfNeeded() }
        statusItemController = StatusItemController(model: model)
        model.start()
        showOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A running `claude` refresh must not outlive QuotaRing.
        model.shutDown()
    }

    /// The first-run window explains what is read and where anything is sent before Live mode can be switched on.
    /// Not shown in demo mode, which touches no real data. When it is already open, it is brought to the front: Settings
    /// and the popover offer that while their switches wait for it.
    private func showOnboardingIfNeeded() {
        guard !isDemo, !settings.hasCompletedOnboarding else { return }
        if let onboardingController {
            onboardingController.show()
            return
        }
        let notifications = notificationService
        let controller = OnboardingWindowController(
            settings: settings,
            liveGate: model,
            requestNotificationPermission: { await notifications.requestAuthorizationIfNeeded() },
            onClose: { [weak self] in self?.onboardingController = nil }
        )
        onboardingController = controller
        controller.show()
    }
}
