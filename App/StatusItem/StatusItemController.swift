import AppKit
import Observation
import QuotaRingCore
import SwiftUI

/// Owns the menu bar item: draws the ring, opens the popover on a left click and the menu on a right click.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private static let tickInterval: Duration = .seconds(30)

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let refreshItem = NSMenuItem()
    private var tickTask: Task<Void, Never>?
    private var openSettingsAction: OpenSettingsAction?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        configureMenu()
        observeModel()
        startTicking()
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusItem.behavior = []

        // Since macOS 14 the `showSettingsWindow:` action no longer opens a SwiftUI Settings scene (it only logs
        // "Please use SettingsLink"). SwiftUI's own `openSettings` action does, but only exists inside a view, so an
        // invisible view living in the status item hands it over.
        let bridge = NSHostingView(
            rootView: SettingsActionBridge { [weak self] action in
                self?.openSettingsAction = action
            })
        bridge.frame = .zero
        bridge.setAccessibilityElement(false)
        button.addSubview(bridge)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        refreshItem.title = String(localized: "Refresh", comment: "Status item menu: reload usage now")
        refreshItem.action = #selector(refreshNow)
        refreshItem.target = self
        refreshItem.keyEquivalent = "r"
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(
            title: String(localized: "Settings…", comment: "Status item menu: open the Settings window"),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(
            title: String(localized: "About QuotaRing", comment: "Status item menu: show the About panel"),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: String(localized: "Quit QuotaRing", comment: "Status item menu: quit the app"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Rendering

    /// Re-renders whenever anything the item shows changes; the tick covers the passage of time.
    private func observeModel() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.observeModel() }
        }
    }

    private func startTicking() {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.render()
            }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let presentation = StatusPresentation(model: model, now: Date())
        button.image = RingImageRenderer.image(fraction: presentation.fraction, style: presentation.style)
        button.title = presentation.text ?? ""
        button.imagePosition = presentation.text == nil ? .imageOnly : .imageLeading
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        button.toolTip = presentation.accessibilityLabel
    }

    // MARK: - Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showMenu() {
        if popover.isShown {
            popover.performClose(nil)
        }
        // Attaching the menu only while it is open keeps left clicks free for the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshItem.isEnabled = model.canRefreshNow
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    func popoverDidShow(_ notification: Notification) {
        model.popoverDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverDidClose()
    }

    // MARK: - Menu actions

    @objc private func refreshNow() {
        Task { await model.refresh(userInitiated: true) }
    }

    @objc private func openSettings() {
        NSApp.activate()
        if let openSettingsAction {
            openSettingsAction()
        } else {
            // Only before the bridge view appeared; works on systems that still honor the legacy action.
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// What the status item shows for a model state at a point in time.
struct StatusPresentation {
    var fraction: Double?
    var style: RingStyle
    var text: String?
    var accessibilityLabel: String

    @MainActor
    init(model: AppModel, now: Date) {
        let settings = model.settings
        var style = RingStyle()
        if settings.isLiveModeActive {
            switch model.liveStatus {
            case .expired, .noCredential, .error:
                style.needsAttention = true
            case .off, .ok, .rateLimited:
                break
            }
        }

        guard let session = model.session(at: now) else {
            fraction = nil
            text = nil
            accessibilityLabel = String(
                localized: "QuotaRing: no usage data yet",
                comment: "VoiceOver label of the menu bar item before any usage is known")
            self.style = style
            return
        }

        let remaining = session.percentRemaining
        let shown = settings.ringShowsRemaining ? remaining : 100 - remaining
        fraction = shown / 100
        style.tint = RingStyle.tint(forRemaining: remaining)
        style.isStale = model.isStale(at: now)
        self.style = style

        let percent = QuotaFormat.percent(shown)
        text = settings.showPercentText ? percent : nil

        var label: String
        switch (settings.ringShowsRemaining, session.resetsAt) {
        case (true, let resetsAt?):
            let countdown = Self.spokenCountdown(to: resetsAt, from: now)
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit remaining, resets in \(countdown)",
                comment: "VoiceOver label of the menu bar item; a percentage and a duration such as 2 hours, 14 minutes"
            )
        case (true, nil):
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit remaining",
                comment: "VoiceOver label of the menu bar item; the argument is a percentage")
        case (false, let resetsAt?):
            let countdown = Self.spokenCountdown(to: resetsAt, from: now)
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit used, resets in \(countdown)",
                comment: "VoiceOver label of the menu bar item; a percentage and a duration such as 2 hours, 14 minutes"
            )
        case (false, nil):
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit used",
                comment: "VoiceOver label of the menu bar item; the argument is a percentage")
        }
        if style.isStale, let snapshot = model.snapshot {
            let age = QuotaFormat.age(of: snapshot.fetchedAt, now: now)
            label +=
                " "
                + String(
                    localized: "Last updated \(age).",
                    comment:
                        "Appended to the menu bar VoiceOver label when the data is old; the argument is like 3 h ago")
        }
        if style.needsAttention {
            label +=
                " "
                + String(
                    localized: "Live mode needs attention.",
                    comment: "Appended to the menu bar VoiceOver label when Live mode cannot fetch")
        }
        accessibilityLabel = label
    }

    /// A duration for speech, for example "2 hours, 14 minutes" (the compact "2h 14m" reads poorly aloud).
    private static func spokenCountdown(to date: Date, from now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval >= 60 else {
            return String(localized: "less than a minute", comment: "Spoken countdown shorter than one minute")
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? QuotaFormat.countdown(to: date, from: now)
    }
}

/// An invisible view that passes SwiftUI's `openSettings` action to AppKit code.
private struct SettingsActionBridge: View {
    let resolve: (OpenSettingsAction) -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { resolve(openSettings) }
    }
}
