import AppKit
import SwiftUI

/// Shows the first-run window in its own centered window. Closing it with the red button counts as choosing
/// "Use without Live mode".
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let model: OnboardingModel
    private let onClose: () -> Void
    private var window: NSWindow?

    /// - Parameters:
    ///   - liveGate: holds Live mode's first Keychain read while the notification prompt is open.
    ///   - requestNotificationPermission: shows the system notification prompt (see ``OnboardingModel``).
    ///   - onClose: called once, after onboarding was completed and the window is gone.
    init(
        settings: SettingsStore,
        liveGate: any LiveRequestGate,
        requestNotificationPermission: @escaping @MainActor () async -> Void,
        onClose: @escaping () -> Void
    ) {
        model = OnboardingModel(
            settings: settings, liveGate: liveGate, requestNotificationPermission: requestNotificationPermission)
        self.onClose = onClose
        super.init()
    }

    func show() {
        let window = makeWindow()
        self.window = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: OnboardingView(model: model) { [weak self] enableLiveMode in
                self?.choose(enableLiveMode: enableLiveMode)
            })
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "Welcome to QuotaRing", comment: "Title of the first-run window")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func choose(enableLiveMode: Bool) {
        model.finish(enableLiveMode: enableLiveMode)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // The red button: the safe default.
        model.finish(enableLiveMode: false)
        window?.delegate = nil
        window = nil
        onClose()
    }
}
