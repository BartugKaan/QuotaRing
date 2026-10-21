import QuotaRingCore
import SwiftUI

/// Something to tell the user about the data: Live mode needs attention, or the numbers are old.
struct PopoverNotice: Identifiable {
    enum Style {
        /// Something needs the user to act or wait (Live mode cannot fetch).
        case warning
        /// Informational: the data is merely old.
        case info
    }

    let id: String
    let style: Style
    let message: LocalizedStringKey

    /// The notices for a Live mode status and the age of the data. Empty when everything is fine.
    ///
    /// - Parameter liveStatus: Pass ``LiveStatus/off`` when Live mode is not in use, so that nothing about it is shown.
    static func notices(liveStatus: LiveStatus, isStale: Bool, now: Date) -> [PopoverNotice] {
        var notices: [PopoverNotice] = []
        switch liveStatus {
        case .off, .ok:
            break
        case .expired:
            notices.append(
                PopoverNotice(
                    id: "expired", style: .warning,
                    message: "Live mode paused: Claude Code login expired — run `claude` once to renew"))
        case .noCredential:
            notices.append(
                PopoverNotice(
                    id: "noCredential", style: .warning,
                    message: "Live mode found no Claude Code login — run `claude` once to sign in"))
        case .rateLimited(let until):
            let countdown = QuotaFormat.countdown(to: until, from: now, locale: .current)
            notices.append(
                PopoverNotice(
                    id: "rateLimited", style: .warning,
                    message: "Live mode is rate limited — trying again in \(countdown)"))
        case .error:
            notices.append(
                PopoverNotice(
                    id: "error", style: .warning,
                    message: "Live mode could not reach Anthropic — showing the last known usage"))
        }
        if isStale {
            notices.append(
                PopoverNotice(
                    id: "stale", style: .info,
                    message: "Data is out of date — run `/usage` in Claude Code, or open it, to refresh"))
        }
        return notices
    }
}

/// The hints at the top of the scrollable content: one row per notice, nothing when there are none.
struct NoticeStack: View {
    let notices: [PopoverNotice]

    var body: some View {
        if !notices.isEmpty {
            VStack(spacing: 8) {
                ForEach(notices) { notice in
                    NoticeRow(notice: notice)
                }
            }
            .padding(.horizontal, PopoverMetrics.inset)
            .padding(.top, 12)
        }
    }
}

/// The popover's bottom bar, always on screen and always one row: where the numbers came from and how old they are,
/// and Refresh, Settings and Quit.
struct FooterView: View {
    /// "Claude Code · 3 min ago", "Live · 1 min ago" or "Demo data"; `nil` before any snapshot exists.
    let source: String?
    let isRefreshing: Bool
    let canRefresh: Bool
    let isCoolingDown: Bool
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            if let source {
                Text(source)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            refreshButton
            settingsButton
            quitButton
        }
        .padding(.horizontal, PopoverMetrics.inset)
        .padding(.vertical, 10)
    }

    // MARK: - Buttons

    private var refreshButton: some View {
        Button(action: onRefresh) {
            ZStack {
                Image(systemName: "arrow.clockwise")
                    .opacity(isRefreshing ? 0 : 1)
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
        }
        .buttonStyle(FooterIconButtonStyle())
        .disabled(!canRefresh)
        .keyboardShortcut("r", modifiers: .command)
        .help(refreshHelp)
        .accessibilityLabel(Text("Refresh", comment: "Popover footer button: reload usage now"))
        .accessibilityValue(
            isRefreshing ? Text("Refreshing", comment: "VoiceOver: a refresh is in progress") : Text(verbatim: ""))
    }

    private var refreshHelp: LocalizedStringKey {
        if isRefreshing {
            "Refreshing…"
        } else if isCoolingDown {
            "Just refreshed. Live requests are limited to one a minute."
        } else {
            "Refresh now"
        }
    }

    private var settingsButton: some View {
        Button(action: onSettings) {
            Image(systemName: "gearshape")
        }
        .buttonStyle(FooterIconButtonStyle())
        .keyboardShortcut(",", modifiers: .command)
        .help("Settings…")
        .accessibilityLabel(Text("Settings", comment: "Popover footer button: open the Settings window"))
    }

    private var quitButton: some View {
        Button(action: onQuit) {
            Image(systemName: "power")
        }
        .buttonStyle(FooterIconButtonStyle())
        .keyboardShortcut("q", modifiers: .command)
        .help("Quit QuotaRing")
        .accessibilityLabel(Text("Quit QuotaRing", comment: "Popover footer button: quit the app"))
    }
}

// MARK: - Pieces

/// One hint line with an icon, in a faint tinted box.
private struct NoticeRow: View {
    let notice: PopoverNotice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(notice.message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch notice.style {
        case .warning: "exclamationmark.triangle.fill"
        case .info: "clock.badge.exclamationmark"
        }
    }

    private var color: Color {
        switch notice.style {
        case .warning: .orange
        case .info: .secondary
        }
    }
}

/// A borderless icon button that shows a rounded highlight on hover and while pressed.
private struct FooterIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isEnabled ? .secondary : .tertiary)
                .frame(width: 28, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(highlight))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
        }

        private var highlight: Double {
            guard isEnabled else { return 0 }
            if configuration.isPressed { return 0.14 }
            return isHovering ? 0.08 : 0
        }
    }
}

#if DEBUG
    #Preview("Footer") {
        FooterView(
            source: "Claude Code · 3 min ago", isRefreshing: false, canRefresh: true,
            isCoolingDown: false, onRefresh: {}, onSettings: {}, onQuit: {}
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Footer, refreshing") {
        FooterView(
            source: "Live · 12 min ago", isRefreshing: true, canRefresh: false, isCoolingDown: false,
            onRefresh: {}, onSettings: {}, onQuit: {}
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Notices") {
        NoticeStack(
            notices:
                PopoverNotice.notices(liveStatus: .expired, isStale: true, now: .now)
                + PopoverNotice.notices(
                    liveStatus: .rateLimited(until: .now.addingTimeInterval(240)), isStale: false, now: .now)
        )
        .frame(width: PopoverMetrics.width)
    }
#endif
