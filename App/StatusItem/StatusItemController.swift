import AppKit
import Observation
import QuotaRingCore
import SwiftUI

/// Owns the menu bar item: draws the ring, opens the popover on a left click and the menu on a right click.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private static let tickInterval: Duration = .seconds(30)
    /// A click on the item within this many seconds after the popover started closing is the click that closed it.
    private static let reopenGuard: TimeInterval = 0.5

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let menu = NSMenu()
    private let refreshItem = NSMenuItem()
    private var tickTask: Task<Void, Never>?
    private var openSettingsAction: OpenSettingsAction?
    /// `systemUptime` when the popover last started closing.
    private var popoverCloseStartedAt: TimeInterval?
    /// What the button shows, so that `render()` touches it only for what changed.
    private var buttonState = StatusButtonState()
    /// Whether all displays are asleep: nobody can see the item, so it is not redrawn until they wake.
    private var screensAreAsleep = false
    private var screenObservers: [any NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()
        configureMenu()
        observeScreens()
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
        // No content yet: the SwiftUI hierarchy is made when the popover opens and dropped when it has closed (see
        // `makePopoverContent()`).
    }

    /// The popover's content, made anew each time it opens. While it exists, SwiftUI keeps the whole view tree alive
    /// and its `TimelineView` keeps refreshing it every 30 s, closed or not: after the first opening that cost 18 MiB
    /// and about three times the idle CPU for as long as the app ran. Whatever must survive the next opening (the
    /// Activity range) lives in ``AppModel``.
    private func makePopoverContent() -> NSViewController {
        let hosting = NSHostingController(rootView: PopoverView(model: model))
        hosting.sizingOptions = .preferredContentSize
        return hosting
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

    /// Re-renders whenever anything the item shows changes; the tick covers the passage of time (and lets the model
    /// notice a session reset that no new data has reported yet).
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
                // The model still notices a session reset while the displays sleep; only the drawing waits.
                self?.model.timeDidPass()
                self?.renderUnlessScreensSleep()
            }
        }
    }

    /// The displays going to sleep and waking up: nothing is drawn for an item nobody can see, and the first thing
    /// after waking is one render, which brings it up to date.
    private func observeScreens() {
        let center = NSWorkspace.shared.notificationCenter
        screenObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.screensAreAsleep = true }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screensAreAsleep = false
                    self?.render()
                }
            },
        ]
    }

    private func renderUnlessScreensSleep() {
        guard !screensAreAsleep else { return }
        render()
    }

    /// The item was clicked or its popover shown, so a display is awake whatever a missed wake notification says.
    /// Without this a lost `screensDidWake` would leave the item undrawn until the next restart.
    private func screensAreEvidentlyAwake() {
        guard screensAreAsleep else { return }
        screensAreAsleep = false
        render()
    }

    /// Brings the button up to date with the model, touching only what changed (see ``StatusButtonState``).
    ///
    /// The presentation is always computed, also while the displays sleep: reading the model is what makes
    /// ``observeModel()`` notice the next change, and it costs microseconds.
    private func render() {
        guard let button = statusItem.button else { return }
        let presentation = StatusPresentation(model: model, now: Date())
        guard !screensAreAsleep else { return }

        let changes = buttonState.update(to: presentation)
        if changes.contains(.image) {
            button.image = RingImageRenderer.image(fraction: presentation.fraction, style: presentation.style)
        }
        if changes.contains(.title) {
            if let text = presentation.text, presentation.isTextDimmed {
                // Old numbers must not look as current as fresh ones.
                let font =
                    button.font ?? NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                button.attributedTitle = NSAttributedString(
                    string: text, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            } else {
                button.title = presentation.text ?? ""
            }
            button.imagePosition = presentation.text == nil ? .imageOnly : .imageLeading
        }
        if changes.contains(.accessibility) {
            button.setAccessibilityLabel(presentation.accessibilityLabel)
            button.toolTip = presentation.accessibilityLabel
        }
    }

    // MARK: - Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        screensAreEvidentlyAwake()
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
        // A transient popover closes on the mouse-down of any click outside it, including a click on this item. The
        // action fires on mouse-up; if the close has already finished by then (Reduce Motion, or a long press), the
        // popover would immediately reopen. A click that just closed it must not open it again.
        if let closedAt = popoverCloseStartedAt,
            ProcessInfo.processInfo.systemUptime - closedAt < Self.reopenGuard
        {
            return
        }
        NSApp.activate()
        popover.contentViewController = makePopoverContent()
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
        screensAreEvidentlyAwake()
        model.popoverDidOpen()
    }

    func popoverWillClose(_ notification: Notification) {
        popoverCloseStartedAt = ProcessInfo.processInfo.systemUptime
    }

    func popoverDidClose(_ notification: Notification) {
        // Drops the SwiftUI hierarchy and everything that keeps it running (see `makePopoverContent()`), unless the
        // popover has been opened again already.
        if !popover.isShown {
            popover.contentViewController = nil
        }
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
///
/// Old data never looks current: when the snapshot is stale, the ring is drawn dashed and the percentage dimmed; when
/// it is stale and the session window it describes has already reset, there is no number at all ("–" and an empty
/// dashed ring), because the real usage of the new window is unknown.
struct StatusPresentation {
    var fraction: Double?
    var style: RingStyle
    var text: String?
    /// Whether `text` is drawn in the secondary label color (the data is out of date).
    var isTextDimmed = false
    var accessibilityLabel: String

    init(fraction: Double?, style: RingStyle, text: String?, isTextDimmed: Bool = false, accessibilityLabel: String) {
        self.fraction = fraction
        self.style = style
        self.text = text
        self.isTextDimmed = isTextDimmed
        self.accessibilityLabel = accessibilityLabel
    }

    @MainActor
    init(model: AppModel, now: Date) {
        let settings = model.settings
        var style = RingStyle()
        if settings.isLiveModeActive {
            switch model.liveStatus {
            case .expired, .noCredential, .keychainDenied, .error:
                style.needsAttention = true
            case .off, .ok, .rateLimited:
                break
            }
        }

        guard let snapshot = model.snapshot, let session = model.session(at: now) else {
            fraction = nil
            text = nil
            accessibilityLabel = String(
                localized: "QuotaRing: no usage data yet",
                comment: "VoiceOver label of the menu bar item before any usage is known")
            self.style = style
            return
        }

        let isStale = model.isStale(at: now)
        style.isStale = isStale
        isTextDimmed = isStale

        if isStale, snapshot.sessionHasReset(at: now) {
            fraction = nil
            text = settings.showPercentText ? "–" : nil
            self.style = style
            accessibilityLabel =
                String(
                    localized: "QuotaRing: the 5-hour session has reset, waiting for fresh data.",
                    comment: "VoiceOver label of the menu bar item when the session reset and no newer data arrived")
                + " " + Self.outOfDateNote(snapshot: snapshot, now: now, needsAttention: style.needsAttention)
            return
        }

        let remaining = session.percentRemaining
        let shown = settings.ringShowsRemaining ? remaining : 100 - remaining
        fraction = shown / 100
        style.tint = RingStyle.tint(forRemaining: remaining)
        self.style = style

        let percent = QuotaFormat.percent(shown)
        text = settings.showPercentText ? percent : nil

        var label: String
        switch (settings.ringShowsRemaining, session.resetsAt) {
        case (true, let resetsAt?):
            let countdown = QuotaFormat.spokenCountdown(to: resetsAt, from: now)
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit remaining, resets in \(countdown)",
                comment: "VoiceOver label of the menu bar item; a percentage and a duration such as 2 hours, 14 minutes"
            )
        case (true, nil):
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit remaining",
                comment: "VoiceOver label of the menu bar item; the argument is a percentage")
        case (false, let resetsAt?):
            let countdown = QuotaFormat.spokenCountdown(to: resetsAt, from: now)
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit used, resets in \(countdown)",
                comment: "VoiceOver label of the menu bar item; a percentage and a duration such as 2 hours, 14 minutes"
            )
        case (false, nil):
            label = String(
                localized: "QuotaRing: \(percent) of 5-hour limit used",
                comment: "VoiceOver label of the menu bar item; the argument is a percentage")
        }
        if isStale {
            label += ". " + Self.outOfDateNote(snapshot: snapshot, now: now, needsAttention: style.needsAttention)
        } else if style.needsAttention {
            label += ". " + Self.liveNeedsAttention
        }
        accessibilityLabel = label
    }

    /// "Out of date, last updated 3 h ago.", plus the Live mode note when it applies.
    private static func outOfDateNote(snapshot: UsageSnapshot, now: Date, needsAttention: Bool) -> String {
        let age = QuotaFormat.age(of: snapshot.fetchedAt, now: now)
        let note = String(
            localized: "Out of date, last updated \(age).",
            comment: "Appended to the menu bar VoiceOver label when the data is old; the argument is like 3 h ago")
        return needsAttention ? note + " " + liveNeedsAttention : note
    }

    private static var liveNeedsAttention: String {
        String(
            localized: "Live mode needs attention.",
            comment: "Appended to the menu bar VoiceOver label when Live mode cannot fetch")
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
