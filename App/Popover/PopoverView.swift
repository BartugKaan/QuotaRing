import AppKit
import QuotaRingCore
import SwiftUI

/// The popover that opens from the menu bar item: the 5-hour session, the weekly limits, local activity and a footer
/// with the data source, refresh, Settings and Quit.
///
/// The view only reads ``AppModel``; every setting that needs consent (Live mode) is changed in Settings, never here.
struct PopoverView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

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
                .frame(maxHeight: PopoverMetrics.maxScrollHeight)

                Divider()
                footer(now: context.date)
            }
        }
        .frame(width: PopoverMetrics.width)
    }

    // MARK: - Sections

    @ViewBuilder
    private func sections(now: Date) -> some View {
        if let snapshot = model.snapshot {
            SessionSection(
                session: model.session(at: now),
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
            NoDataSection(isLiveModeActive: model.settings.isLiveModeActive, openSettings: showSettings)
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
            notices: FooterNotice.notices(
                liveStatus: model.settings.isLiveModeActive && !model.isDemo ? model.liveStatus : .off,
                isStale: model.isStale(at: now),
                now: now
            ),
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
}

// MARK: - Shared building blocks

enum PopoverMetrics {
    static let width: CGFloat = 340
    /// Leading and trailing space of every section.
    static let inset: CGFloat = 16

    /// The most the scrollable part may grow: what the screen can show next to the footer, so a long Activity list on a
    /// small display scrolls instead of running off the screen.
    @MainActor static var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        // The footer, the popover arrow and some breathing room come on top of this.
        return max(320, screenHeight - 130)
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

/// The color of a limit with a given share left: the accent color, orange at 20 % or less and red at 5 % or less
/// (the same thresholds as the menu bar ring).
enum UsageTint {
    static func color(percentRemaining: Double) -> Color {
        switch RingStyle.tint(forRemaining: percentRemaining) {
        case .standard: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Date and duration formatting shared by the sections.
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

    /// A duration for speech, for example "2 hours, 14 minutes" (the compact "2h 14m" reads poorly aloud).
    static func spokenCountdown(until date: Date, from now: Date) -> String {
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

    /// A token count for speech, for example "4.2 million".
    static func spokenTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }
}

// MARK: - No data

/// Shown when no usage snapshot exists at all: where the numbers come from, and the way to Live mode.
struct NoDataSection: View {
    let isLiveModeActive: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("No usage data yet")
                    .font(.headline)
                if isLiveModeActive {
                    Text("Live mode is on. The first reading should arrive in a moment.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        "QuotaRing shows the numbers Claude Code keeps on this Mac. Use Claude Code, or run `/usage` there, and they appear here."
                    )
                    .foregroundStyle(.secondary)
                    Text("For up-to-date limits without opening Claude Code, you can turn on Live mode in Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            if isLiveModeActive {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Enable Live mode…", action: openSettings)
                    .controlSize(.large)
                    .help("Open Settings, where Live mode is explained and can be turned on")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PopoverMetrics.inset + 6)
        .padding(.vertical, 24)
    }
}

#if DEBUG
    /// Models for previews and for rendering the popover offscreen. None of them reads any file or credential.
    @MainActor
    enum PopoverPreviewSupport {
        static func settings(showsRemaining: Bool = true) -> SettingsStore {
            let defaults = UserDefaults(suiteName: "io.github.bartugkaan.QuotaRing.preview." + UUID().uuidString)!
            let settings = SettingsStore(defaults: defaults)
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
#endif
