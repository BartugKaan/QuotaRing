import AppKit
import QuotaRingCore
import SwiftUI

/// The popover that opens from the menu bar item: the 5-hour session, the weekly limits, local activity and a footer
/// with the data source, refresh, Settings and Quit.
///
/// The footer row is always on screen; everything else, including hints about Live mode, auto-refresh and old data,
/// scrolls when the screen is too small to show it. The view only reads ``AppModel``; every setting that needs consent
/// (Live mode, auto-refresh) is changed in Settings, never here.
struct PopoverView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    /// The height of the footer row as measured; the scrollable part gets what is left of the screen.
    @State private var footerHeight = PopoverMetrics.footerHeightEstimate
    /// The visible height of the screen the popover is on, once its window is known.
    @State private var hostScreenHeight: CGFloat?

    var body: some View {
        // One timeline for the whole popover keeps every countdown, clock and age in step.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        sections(now: context.date)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    maxHeight: PopoverMetrics.maxScrollHeight(
                        screenHeight: hostScreenHeight ?? PopoverMetrics.pointerScreenHeight(),
                        footerHeight: footerHeight)
                )

                Divider()
                footer(now: context.date)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        footerHeight = $0
                    }
            }
        }
        .frame(width: PopoverMetrics.width)
        .background(HostScreenReader { hostScreenHeight = $0 })
    }

    // MARK: - Sections

    /// What Live mode's status means for the user; `.off` when Live mode is not in use (or in demo mode).
    private var liveStatus: LiveStatus {
        model.settings.isLiveModeActive && !model.isDemo ? model.liveStatus : .off
    }

    /// Auto-refresh's status; `.off` in demo mode.
    private var cliStatus: CLIRefreshStatus {
        model.isDemo ? .off : model.cliStatus
    }

    private var isCLIRefreshActive: Bool {
        model.settings.isCLIRefreshActive && !model.isDemo
    }

    @ViewBuilder
    private func sections(now: Date) -> some View {
        if let snapshot = model.snapshot {
            NoticeStack(
                notices: PopoverNotice.notices(
                    liveStatus: liveStatus, cliStatus: cliStatus, isCLIRefreshActive: isCLIRefreshActive,
                    cacheProblem: model.cacheProblem, isStale: model.isStale(at: now), now: now),
                onAction: { _ in showDataSettings() })
            SessionSection(
                session: snapshot.report.session,
                showsRemaining: model.settings.ringShowsRemaining,
                isStale: model.isStale(at: now),
                now: now
            )
            if WeeklySection.hasContent(snapshot.report) {
                SectionDivider()
                WeeklySection(report: snapshot.report, now: now)
            }
            SectionDivider()
            ActivitySection(activity: model.activity, daily: model.daily, now: now)
        } else {
            // A cache file that exists but cannot be read is the likely reason for having no data at all. Auto-refresh's
            // problems are listed here too, unless the section below is about auto-refresh and says it itself. Why it
            // turned itself off is always listed, until it is turned on again.
            let isLiveModeActive = model.settings.isLiveModeActive && !model.isDemo
            let showsCLINotice = isLiveModeActive || cliStatus.isSafetyStop
            let cliNotice =
                showsCLINotice ? PopoverNotice.cliNotice(for: cliStatus, isActive: isCLIRefreshActive, now: now) : nil
            NoticeStack(
                notices: [cliNotice, PopoverNotice.cacheNotice(for: model.cacheProblem)].compactMap { $0 },
                onAction: { _ in showDataSettings() })
            // Without any snapshot the section itself explains what Live mode or auto-refresh is waiting for or needs.
            NoDataSection(
                isLiveModeActive: isLiveModeActive,
                liveStatus: liveStatus,
                isCLIRefreshActive: isCLIRefreshActive,
                cliStatus: cliStatus,
                needsOnboarding: !model.isDemo && !model.settings.hasCompletedOnboarding,
                now: now,
                openDataSettings: showDataSettings,
                showWelcomeWindow: { model.showWelcomeWindow?() }
            )
            // Local transcripts need no consent, so their activity can be shown even before any limit is known.
            if model.activity.values.contains(where: { $0.total.total > 0 }) {
                SectionDivider()
                ActivitySection(activity: model.activity, daily: model.daily, now: now)
            }
        }
    }

    private func footer(now: Date) -> some View {
        FooterView(
            source: sourceDescription(now: now),
            isRefreshing: model.isRefreshing,
            canRefresh: model.canRefreshNow,
            isCoolingDown: model.isCoolingDown,
            onRefresh: { Task { await model.refresh(userInitiated: true) } },
            onSettings: showSettings,
            onQuit: { NSApp.terminate(nil) }
        )
    }

    /// "Claude Code · 3 min ago", "Live · 1 min ago" or "Demo data"; `nil` before any snapshot exists.
    private func sourceDescription(now: Date) -> String? {
        guard let snapshot = model.snapshot else { return nil }
        if model.isDemo || snapshot.source == .demo {
            return String(localized: "Demo data", comment: "Popover footer: the numbers shown are made-up demo data")
        }
        let age = QuotaFormat.age(of: snapshot.fetchedAt, now: now, locale: .current)
        switch snapshot.source {
        case .live:
            return String(
                localized: "Live · \(age)",
                comment: "Popover footer: data came from Anthropic's usage endpoint; the argument is like 3 min ago")
        case .claudeCodeCache, .demo:
            return String(
                localized: "Claude Code · \(age)",
                comment: "Popover footer: data came from Claude Code's own cache; the argument is like 3 min ago")
        }
    }

    private func showSettings() {
        // QuotaRing is an accessory app: without activating it, the Settings window opens behind other apps.
        NSApp.activate()
        openSettings()
    }

    /// Settings on the Data tab, where Live mode and auto-refresh are explained and can be turned on.
    private func showDataSettings() {
        model.settingsTab = .data
        showSettings()
    }
}

// MARK: - Shared building blocks

enum PopoverMetrics {
    static let width: CGFloat = 340
    /// Leading and trailing space of every section.
    static let inset: CGFloat = 16
    /// A good guess for the footer row until it has been measured.
    static let footerHeightEstimate: CGFloat = 47
    /// What a popover needs on a screen besides its content: the arrow, the divider above the footer and some room
    /// to the bottom of the screen.
    static let screenChrome: CGFloat = 60

    /// The most the scrollable part may grow so that it, the footer and the popover's arrow fit on a screen
    /// `screenHeight` points high (its visible height, below the menu bar and above the Dock). A long Activity list on
    /// a small display scrolls instead of pushing the footer off the screen.
    static func maxScrollHeight(screenHeight: CGFloat, footerHeight: CGFloat) -> CGFloat {
        max(240, screenHeight - footerHeight - screenChrome)
    }

    /// The visible height of the screen under the pointer, which is where the status item was just clicked; used until
    /// the popover's own window tells which screen it is on.
    @MainActor static func pointerScreenHeight() -> CGFloat {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame.height ?? 800
    }
}

/// Reports the visible height of the screen the hosting window is on, and again when the window moves to another
/// screen. The popover's window is where the status item is, which is not necessarily `NSScreen.main`.
private struct HostScreenReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.onChange = onChange
    }

    final class ReportingView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Observers registered with a selector are removed automatically when the view goes away.
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidChangeScreen(_:)), name: NSWindow.didChangeScreenNotification,
                object: window)
            report()
        }

        @objc private func windowDidChangeScreen(_ notification: Notification) {
            report()
        }

        private func report() {
            guard let height = window?.screen?.visibleFrame.height else { return }
            onChange?(height)
        }
    }
}

/// A divider that lines up with the section content.
struct SectionDivider: View {
    var body: some View {
        Divider().padding(.horizontal, PopoverMetrics.inset)
    }
}

/// The title of a popover section.
struct SectionHeader: View {
    private let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The colors of the usage indicators: a fixed calm blue normally, orange at 20 % left or less and red at 5 % or less
/// (the same thresholds as the menu bar ring).
///
/// The normal color is deliberately not the system accent color: with an orange or red accent, a healthy ring would
/// look like a warning.
enum UsageTint {
    /// The blue of the app icon.
    static let normal = Color(red: 0.24, green: 0.48, blue: 1.0)

    static func color(percentRemaining: Double) -> Color {
        switch RingStyle.tint(forRemaining: percentRemaining) {
        case .standard: normal
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Date and number formatting shared by the sections.
enum PopoverFormat {
    /// The local clock time, for example "03:00" or "3:00 AM".
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The weekday and clock time, for example "Sat 09:00".
    static func weekdayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// The same, spelled out for VoiceOver, for example "Saturday 09:00".
    static func spokenWeekdayAndTime(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    /// A token count for speech, for example "4.2 million".
    static func spokenTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }
}

// MARK: - No data

/// Shown when no usage snapshot exists at all: where the numbers come from and the ways to fresh numbers, or, when Live
/// mode or auto-refresh is on, what it is waiting for or needs.
struct NoDataSection: View {
    let isLiveModeActive: Bool
    /// Live mode's status; `.off` when Live mode is not in use.
    let liveStatus: LiveStatus
    let isCLIRefreshActive: Bool
    /// Auto-refresh's status; `.off` when it is not in use.
    let cliStatus: CLIRefreshStatus
    /// The welcome window has not been finished yet, so Live mode and auto-refresh cannot be turned on in Settings.
    var needsOnboarding = false
    let now: Date
    /// Opens Settings on the Data tab; nothing is switched on from here.
    let openDataSettings: () -> Void
    /// Brings the welcome window to the front.
    var showWelcomeWindow: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: needsAttention ? "exclamationmark.triangle" : "circle.dashed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                title
                    .font(.headline)
                messages
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if needsOnboarding {
                // Settings' switches wait for the welcome window, so pointing there would lead to switches that are off.
                Button("Show Welcome Window", action: showWelcomeWindow)
                    .controlSize(.large)
                    .help("Bring the welcome window to the front")
            } else if !isLiveModeActive && !isCLIRefreshActive {
                VStack(spacing: 8) {
                    // After a safety switch-off the notice above explains it and links to Settings; turning it back on
                    // is not suggested here.
                    if !cliStatus.isSafetyStop {
                        Button("Turn on auto-refresh…", action: openDataSettings)
                            .controlSize(.large)
                            .help("Open Settings, where auto-refresh is explained and can be turned on")
                    }
                    Button("Enable Live mode…", action: openDataSettings)
                        .buttonStyle(.link)
                        .help("Open Settings, where Live mode is explained and can be turned on")
                }
            } else if !needsAttention {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PopoverMetrics.inset + 6)
        .padding(.vertical, 24)
    }

    /// Whether this section is about auto-refresh: it is on and Live mode is not.
    private var showsAutoRefresh: Bool {
        isCLIRefreshActive && !isLiveModeActive
    }

    /// Whether Live mode (or, without it, auto-refresh) is on but cannot deliver, so waiting is not the right message.
    private var needsAttention: Bool {
        if showsAutoRefresh {
            return cliStatus.needsAttention
        }
        guard isLiveModeActive else { return false }
        switch liveStatus {
        case .off, .ok: return false
        case .expired, .noCredential, .keychainDenied, .rateLimited, .error: return true
        }
    }

    @ViewBuilder
    private var title: some View {
        if needsOnboarding {
            Text("Finish setting up QuotaRing")
        } else if showsAutoRefresh {
            Text("No usage data yet")
        } else if isLiveModeActive {
            switch liveStatus {
            case .off, .ok:
                Text("No usage data yet")
            case .expired:
                Text("Live mode is paused")
            case .noCredential:
                Text("No Claude Code login found")
            case .keychainDenied:
                Text("Keychain access was denied")
            case .rateLimited:
                Text("Live mode is rate limited")
            case .error:
                Text("Live mode can't reach Anthropic")
            }
        } else {
            Text("No usage data yet")
        }
    }

    @ViewBuilder
    private var messages: some View {
        if needsOnboarding {
            Text("Choose in the welcome window how QuotaRing keeps its numbers fresh.")
        } else if showsAutoRefresh {
            if let message = cliStatus.needsAttention ? CLIRefreshText.statusMessage(cliStatus, now: now) : nil {
                Text(message)
            } else {
                Text("Auto-refresh is on. The first reading should arrive in a moment.")
            }
        } else if isLiveModeActive {
            switch liveStatus {
            case .off, .ok:
                Text("Live mode is on. The first reading should arrive in a moment.")
            case .expired:
                Text("Claude Code's login has expired. Run `claude` once to renew it, and usage will appear here.")
            case .noCredential:
                Text("Live mode needs a Claude Code login. Run `claude` once to sign in, and usage will appear here.")
            case .keychainDenied:
                Text("Click Refresh to ask again, or turn Live mode off.")
            case .rateLimited(let until):
                let countdown = QuotaFormat.countdown(to: until, from: now, locale: .current)
                Text("Anthropic asked QuotaRing to slow down. It tries again in \(countdown).")
            case .error:
                Text("QuotaRing keeps trying. Usage will appear here as soon as a request succeeds.")
            }
        } else {
            Text(
                "QuotaRing shows the numbers the `claude` command-line tool saves on this Mac. Start a session or run `/usage` there, and they appear here. The Claude desktop app does not save them."
            )
            if !cliStatus.isSafetyStop {
                Text("Auto-refresh can run Claude Code's `/usage` for you in the background.")
            }
        }
    }
}

#if DEBUG
    /// Models for previews and for rendering the popover offscreen. None of them reads any file or credential.
    @MainActor
    enum PopoverPreviewSupport {
        static func settings(showsRemaining: Bool = true) -> SettingsStore {
            // A suite named by a path is saved to that file. A plain name would leave a new plist in
            // ~/Library/Preferences for every preview render; the temporary directory is cleaned up by the system.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
                "QuotaRingPreviews", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suite = folder.appendingPathComponent(UUID().uuidString).path
            let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, persistentDomain: suite)
            if !showsRemaining {
                settings.ringShowsRemaining = false
            }
            return settings
        }

        /// The `--demo` data.
        static func demoModel(showsRemaining: Bool = true) -> AppModel {
            AppModel(settings: settings(showsRemaining: showsRemaining), isDemo: true)
        }

        /// A model that never started: no snapshot, no activity.
        static func emptyModel() -> AppModel {
            AppModel(settings: settings(), isDemo: false)
        }
    }

    #Preview("Demo") {
        PopoverView(model: PopoverPreviewSupport.demoModel())
    }

    #Preview("Demo, ring shows used") {
        PopoverView(model: PopoverPreviewSupport.demoModel(showsRemaining: false))
    }

    #Preview("No data") {
        PopoverView(model: PopoverPreviewSupport.emptyModel())
    }

    #Preview("No data, welcome window not finished") {
        NoDataSection(
            isLiveModeActive: false, liveStatus: .off, isCLIRefreshActive: false, cliStatus: .off,
            needsOnboarding: true, now: Date(), openDataSettings: {}
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("No data, Live mode states") {
        let now = Date()
        VStack(spacing: 0) {
            NoDataSection(
                isLiveModeActive: true, liveStatus: .ok, isCLIRefreshActive: false, cliStatus: .off, now: now,
                openDataSettings: {})
            Divider()
            NoDataSection(
                isLiveModeActive: true, liveStatus: .expired, isCLIRefreshActive: false, cliStatus: .off, now: now,
                openDataSettings: {})
            Divider()
            NoDataSection(
                isLiveModeActive: true, liveStatus: .rateLimited(until: now.addingTimeInterval(240)),
                isCLIRefreshActive: false, cliStatus: .off, now: now, openDataSettings: {})
            Divider()
            NoDataSection(
                isLiveModeActive: true, liveStatus: .keychainDenied, isCLIRefreshActive: false, cliStatus: .off,
                now: now, openDataSettings: {})
        }
        .frame(width: PopoverMetrics.width)
    }

    #Preview("No data, auto-refresh states") {
        let now = Date()
        VStack(spacing: 0) {
            NoDataSection(
                isLiveModeActive: false, liveStatus: .off, isCLIRefreshActive: false, cliStatus: .off, now: now,
                openDataSettings: {})
            Divider()
            NoDataSection(
                isLiveModeActive: false, liveStatus: .off, isCLIRefreshActive: true, cliStatus: .running, now: now,
                openDataSettings: {})
            Divider()
            NoDataSection(
                isLiveModeActive: false, liveStatus: .off, isCLIRefreshActive: true, cliStatus: .notLoggedIn,
                now: now, openDataSettings: {})
            Divider()
            NoDataSection(
                isLiveModeActive: false, liveStatus: .off, isCLIRefreshActive: false,
                cliStatus: .disabledForSafety(.unverifiableOutput), now: now, openDataSettings: {})
        }
        .frame(width: PopoverMetrics.width)
    }
#endif
