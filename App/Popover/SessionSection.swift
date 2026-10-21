import QuotaRingCore
import SwiftUI

/// The 5-hour session: a large ring with the share left (or used), and when it resets.
struct SessionSection: View {
    /// The session as it applies at `now` (already shown as reset once its reset time passed), or `nil` when the
    /// usage report has no session limit.
    let session: UsageLimit?
    /// Whether the ring and its label show the share left (`true`) or the share already used.
    let showsRemaining: Bool
    /// The data is old: the arc is drawn faded, like the menu bar ring.
    let isStale: Bool
    let now: Date

    var body: some View {
        VStack(spacing: 10) {
            RingGauge(
                fraction: shownFraction,
                tint: tint,
                isFaded: isStale
            ) {
                ringLabel
            }
            .frame(width: 96, height: 96)

            VStack(spacing: 3) {
                Text("5-hour session")
                    .font(.headline)
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, PopoverMetrics.inset)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Pieces

    /// The share the ring shows, `0...1`; `nil` without session data.
    private var shownFraction: Double? {
        guard let session else { return nil }
        let shown = showsRemaining ? session.percentRemaining : 100 - session.percentRemaining
        return min(1, max(0, shown / 100))
    }

    private var tint: Color {
        guard let session else { return .accentColor }
        return UsageTint.color(percentRemaining: session.percentRemaining)
    }

    private var ringLabel: some View {
        VStack(spacing: 0) {
            if let fraction = shownFraction {
                Text(QuotaFormat.percent(fraction * 100, locale: .current))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if showsRemaining {
                    Text("left", comment: "Under the percentage in the ring: the share of the limit still available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("used", comment: "Under the percentage in the ring: the share of the limit already used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: "–")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session {
            if let resetsAt = session.resetsAt {
                HStack(spacing: 5) {
                    Text("Resets in \(QuotaFormat.countdown(to: resetsAt, from: now, locale: .current))")
                    Text(verbatim: "·")
                        .foregroundStyle(.tertiary)
                    Text(PopoverFormat.clockTime(resetsAt))
                }
                .monospacedDigit()
            } else {
                Text("Waiting for fresh data")
            }
        } else {
            Text("The latest usage report has no 5-hour data.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilityDescription: String {
        let title = String(localized: "5-hour session", comment: "VoiceOver: name of the session ring")
        guard let session, let fraction = shownFraction else {
            return title + ". "
                + String(localized: "No data yet.", comment: "VoiceOver: the session ring has no data")
        }
        let percent = QuotaFormat.percent(fraction * 100, locale: .current)
        var parts = [
            showsRemaining
                ? String(localized: "\(percent) left", comment: "VoiceOver: share of the limit still available")
                : String(localized: "\(percent) used", comment: "VoiceOver: share of the limit already used")
        ]
        if let resetsAt = session.resetsAt {
            let countdown = PopoverFormat.spokenCountdown(until: resetsAt, from: now)
            let time = PopoverFormat.clockTime(resetsAt)
            parts.append(
                String(
                    localized: "Resets in \(countdown), at \(time)",
                    comment: "VoiceOver: a duration such as 2 hours, 14 minutes, then a clock time"))
        } else {
            parts.append(String(localized: "Waiting for fresh data"))
        }
        if isStale {
            parts.append(String(localized: "Data is out of date", comment: "VoiceOver: the shown usage is old"))
        }
        return title + ". " + parts.joined(separator: ". ")
    }
}

/// A ring: a faint full track under an arc that starts at 12 o'clock and runs clockwise, with round caps.
private struct RingGauge<Label: View>: View {
    /// The arc length in `0...1`, or `nil` for a dashed track without data.
    let fraction: Double?
    let tint: Color
    let isFaded: Bool
    @ViewBuilder let label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lineWidth: CGFloat = 10

    var body: some View {
        ZStack {
            if let fraction {
                Circle()
                    .stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(isFaded ? 0.5 : 1)
                    .animation(reduceMotion ? nil : .smooth, value: fraction)
            } else {
                // 24 even segments: the same "no data yet" look as the dashed menu bar ring.
                Circle()
                    .stroke(.quaternary, style: StrokeStyle(lineWidth: lineWidth, dash: [7, 4.26]))
            }
            label
        }
        .padding(lineWidth / 2)
    }
}

#if DEBUG
    #Preview("Session, 72 % left") {
        SessionSection(
            session: DemoData.snapshot(now: .now).report.session, showsRemaining: true, isStale: false, now: .now
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Session, used") {
        SessionSection(
            session: DemoData.snapshot(now: .now).report.session, showsRemaining: false, isStale: false, now: .now
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Session, low, stale") {
        SessionSection(
            session: UsageLimit(kind: .session, percentUsed: 91, resetsAt: .now.addingTimeInterval(1_500)),
            showsRemaining: true, isStale: true, now: .now
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Session, critical") {
        SessionSection(
            session: UsageLimit(kind: .session, percentUsed: 97, resetsAt: .now.addingTimeInterval(600)),
            showsRemaining: true, isStale: false, now: .now
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Session, no data") {
        SessionSection(session: nil, showsRemaining: true, isStale: false, now: .now)
            .frame(width: PopoverMetrics.width)
    }
#endif
