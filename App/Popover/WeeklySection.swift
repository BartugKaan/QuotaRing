import QuotaRingCore
import SwiftUI

/// The weekly limits (all models and any model-scoped ones), limits of kinds QuotaRing has no name for (shown
/// generically), the extra usage row when it is enabled, and Anthropic's own "where it went" breakdown of the week.
struct WeeklySection: View {
    let report: UsageReport
    let now: Date

    /// Whether the report has anything to show in this section.
    static func hasContent(_ report: UsageReport) -> Bool {
        !limits(of: report).isEmpty || report.extraUsage?.hasDisplayableUsage == true
            || !(report.weeklyBreakdown?.rows.isEmpty ?? true)
    }

    /// The rows: the weekly limits, then any limit of a kind the endpoint added later.
    private static func limits(of report: UsageReport) -> [UsageLimit] {
        report.weeklyLimits + report.otherLimits
    }

    private var limits: [UsageLimit] {
        Self.limits(of: report)
    }

    private var showsExtraUsage: Bool {
        report.extraUsage?.hasDisplayableUsage == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if report.otherLimits.isEmpty {
                SectionHeader("Weekly limits")
            } else {
                // Not every row is weekly any more.
                SectionHeader("Limits")
            }

            if !limits.isEmpty || showsExtraUsage {
                VStack(spacing: 12) {
                    ForEach(limits) { limit in
                        LimitRow(limit: limit, now: now)
                    }
                    if let extraUsage = report.extraUsage, extraUsage.hasDisplayableUsage {
                        ExtraUsageRow(extraUsage: extraUsage)
                    }
                }
            }

            if let breakdown = report.weeklyBreakdown, !breakdown.rows.isEmpty {
                if !limits.isEmpty || showsExtraUsage {
                    Divider()
                }
                BreakdownView(rows: breakdown.rows)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopoverMetrics.inset)
        .padding(.vertical, 14)
    }
}

// MARK: - A bar row

/// A title with a secondary detail and the value on the right, and under them a full-width progress bar.
///
/// The detail sits next to the title when everything fits on one line, and wraps under it otherwise, so a long
/// translation is never cut off.
private struct UsageBarRow: View {
    let title: Text
    /// `nil` for no detail.
    let detail: Text?
    /// The filled share of the bar, `0...1`.
    let fraction: Double
    /// Decides the color: the normal blue, orange at 20 % or less left, red at 5 % or less.
    let percentRemaining: Double
    let valueText: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleLabel.fixedSize()
                    if let detail {
                        detailLabel(detail).fixedSize()
                    }
                    Spacer(minLength: 8)
                    valueLabel.fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleLabel.fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        valueLabel.fixedSize()
                    }
                    if let detail {
                        detailLabel(detail).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(UsageBarStyle(tint: UsageTint.color(percentRemaining: percentRemaining)))
        }
    }

    private var titleLabel: some View {
        title.font(.callout.weight(.medium))
    }

    private func detailLabel(_ detail: Text) -> some View {
        detail
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var valueLabel: some View {
        valueText
            .font(.callout)
            .monospacedDigit()
    }
}

/// A 6 pt capsule bar: a faint track under a colored fill.
///
/// The system's linear style cannot be relied on here: with an explicit tint other than the accent color (orange and
/// red warnings) it can lose its track in light mode, and it turns gray whenever its window is not the key window.
private struct UsageBarStyle: ProgressViewStyle {
    let tint: Color
    private let height: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        let fraction = min(1, max(0, configuration.fractionCompleted ?? 0))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if fraction > 0 {
                    // Never narrower than the bar is high, so a small share still shows as a dot.
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, proxy.size.width * fraction))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - One limit

/// A weekly limit, or one of a kind QuotaRing has no name for, titled from what the endpoint calls it.
private struct LimitRow: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        UsageBarRow(
            title: Text(title),
            detail: resetCaption,
            fraction: min(1, max(0, current.percentUsed / 100)),
            percentRemaining: current.percentRemaining,
            valueText: Text("\(percentText) used")
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var title: String {
        switch limit.kind {
        case .weeklyAll:
            String(localized: "All models", comment: "Weekly limit that covers every model")
        case .weeklyScoped:
            limit.scopeName ?? String(localized: "One model", comment: "Weekly limit for a model whose name is unknown")
        case .session, .other:
            // The session has its own section, so only unknown kinds get here.
            limit.genericTitle
                ?? String(localized: "Other limit", comment: "Title of a usage limit of a kind QuotaRing does not know")
        }
    }

    /// The limit as it applies now: a window whose reset time has passed counts as fresh (0 % used), like the session.
    private var current: UsageLimit {
        limit.effective(at: now)
    }

    private var percentText: String {
        QuotaFormat.percent(current.percentUsed, locale: .current)
    }

    private var resetCaption: Text {
        switch limit.windowState(at: now) {
        case .resetsAt(let resetsAt):
            Text("Resets \(PopoverFormat.weekdayAndTime(resetsAt))")
        case .resetPassed:
            Text("Waiting for fresh data")
        case .resetTimeUnknown, .notStarted:
            Text("Reset time unknown")
        }
    }

    private var accessibilityValue: String {
        let used = String(localized: "\(percentText) used", comment: "VoiceOver: share of a limit already used")
        guard let resetsAt = limit.resetsAt, resetsAt > now else { return used }
        let when = PopoverFormat.spokenWeekdayAndTime(resetsAt)
        return used + ". " + String(localized: "Resets \(when)", comment: "VoiceOver: weekday and time of the reset")
    }
}

// MARK: - Extra usage

/// Pay-as-you-go spending beyond the plan, shown only when the account has it enabled and something about it is
/// known. The saved snapshot shown at launch keeps no money amounts; then only the percentage is shown.
private struct ExtraUsageRow: View {
    let extraUsage: ExtraUsage

    var body: some View {
        Group {
            if let fraction {
                UsageBarRow(
                    title: Text("Extra usage"),
                    detail: amountDescription.map { Text($0) },
                    fraction: fraction,
                    percentRemaining: 100 - fraction * 100,
                    valueText: Text("\(QuotaFormat.percent(fraction * 100, locale: .current)) used")
                )
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Extra usage")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(amountDescription ?? "")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Extra usage"))
        .accessibilityValue(Text(accessibilityValue))
    }

    /// The share of the monthly limit spent, `0...1`; `nil` when unknown.
    private var fraction: Double? {
        extraUsage.fractionUsed
    }

    private var accessibilityValue: String {
        let used = fraction.map {
            String(
                localized: "\(QuotaFormat.percent($0 * 100, locale: .current)) used",
                comment: "VoiceOver: share of a limit already used")
        }
        return [amountDescription, used].compactMap { $0 }.joined(separator: ". ")
    }

    /// "$12.40 of $50.00", or just "$12.40" without a limit; `nil` when the amount spent is not known.
    private var amountDescription: String? {
        guard let usedMinor = extraUsage.usedCreditsMinor else { return nil }
        let used = money(usedMinor)
        guard let limit = extraUsage.monthlyLimitMinor else { return used }
        let cap = money(limit)
        return String(localized: "\(used) of \(cap)", comment: "Extra usage: amount spent of the monthly limit")
    }

    /// Minor units (cents) as money in the account's currency.
    private func money(_ minor: Double) -> String {
        let places = max(0, extraUsage.decimalPlaces ?? 2)
        let amount = minor / pow(10, Double(places))
        if let code = extraUsage.currency, !code.isEmpty {
            return amount.formatted(.currency(code: code).precision(.fractionLength(places)))
        }
        return amount.formatted(.number.precision(.fractionLength(places)))
    }
}

// MARK: - Where it went

/// A stacked bar of Anthropic's breakdown of the week across Claude Code, Chats, Cowork and the rest, with a legend.
private struct BreakdownView: View {
    let rows: [BreakdownRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Where it went")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text("Anthropic's breakdown, all devices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }

            SegmentedBar(segments: segments)
                .frame(height: 8)
                .accessibilityHidden(true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16, alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 3
            ) {
                ForEach(segments) { segment in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(segment.color)
                            .frame(width: 8, height: 8)
                        Text(segment.name)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(QuotaFormat.percent(segment.percent, locale: .current))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Where it went"))
        .accessibilityValue(Text(spokenSummary))
    }

    private var segments: [Segment] {
        var next = 0
        // The position is the identity: keys are not guaranteed to be unique in a response.
        return rows.enumerated().map { index, row in
            let color: Color
            if row.key == "other" {
                color = .gray
            } else {
                color = Self.palette[next % Self.palette.count]
                next += 1
            }
            return Segment(id: index, name: row.displayName, percent: row.percent, color: color)
        }
    }

    private var spokenSummary: String {
        segments
            .map { "\($0.name) \(QuotaFormat.percent($0.percent, locale: .current))" }
            .joined(separator: ", ")
    }

    /// Distinct system colors that stay readable in light and dark mode; orange and red are left to warnings.
    private static let palette: [Color] = [.blue, .purple, .teal, .pink, .indigo, .brown]

    struct Segment: Identifiable {
        let id: Int
        let name: String
        let percent: Double
        let color: Color
    }
}

/// Colored segments side by side in one capsule; the part of the track no segment covers stays empty.
private struct SegmentedBar: View {
    let segments: [BreakdownView.Segment]

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.percent > 0 }
            let gap: CGFloat = 2
            let usable = max(0, proxy.size.width - gap * CGFloat(max(visible.count - 1, 0)))
            // The shares normally add up to 100; if rounding made them add up to more, they are scaled down to fit.
            let total = max(100, visible.reduce(0) { $0 + $1.percent })
            HStack(spacing: gap) {
                ForEach(visible) { segment in
                    segment.color
                        .frame(width: usable * segment.percent / total)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .clipShape(Capsule())
        }
        .background(Capsule().fill(.quaternary))
    }
}

#if DEBUG
    #Preview("Weekly, demo") {
        WeeklySection(report: DemoData.snapshot(now: .now).report, now: .now)
            .frame(width: PopoverMetrics.width)
    }

    #Preview("Weekly, saved snapshot and an unknown kind") {
        var report = DemoData.snapshot(now: .now).report
        report.extraUsage = ExtraUsage(isEnabled: true, percentUsed: 24.8)
        report.limits.append(
            UsageLimit(kind: .other("monthly_pool"), percentUsed: 37, resetsAt: .now.addingTimeInterval(9 * 86_400)))
        return WeeklySection(report: report, now: .now)
            .frame(width: PopoverMetrics.width)
    }

    #Preview("Weekly, extra usage") {
        var report = DemoData.snapshot(now: .now).report
        report.extraUsage = ExtraUsage(
            isEnabled: true, monthlyLimitMinor: 5_000, usedCreditsMinor: 1_240, percentUsed: 24.8,
            currency: "USD", decimalPlaces: 2)
        report.limits[1].percentUsed = 93
        return WeeklySection(report: report, now: .now)
            .frame(width: PopoverMetrics.width)
    }
#endif
