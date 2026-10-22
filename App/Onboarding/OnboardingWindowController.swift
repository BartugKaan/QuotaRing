import AppKit
import SwiftUI

/// Shows the first-run window in its own centered window. Closing it with the red button turns on nothing: Live mode and
/// auto-refresh are recorded off, whatever the window shows.
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
        // The hosting view sizes the window only in its first layout pass. Centering the still-empty window and letting
        // it grow afterwards pushes its top above the screen; AppKit then keeps constraining that frame while SwiftUI
        // keeps resizing it, until AppKit gives up with an exception. So lay out first and center the final size.
        if let content = window.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
        }
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
        // The red button: no choice was made, so nothing that runs or reads is turned on.
        model.finish(enableLiveMode: false, closedWindow: true)
        window?.delegate = nil
        window = nil
        onClose()
    }
}
