import QuotaRingCore
import SwiftUI

/// The weekly limits (all models and any model-scoped ones), the extra usage row when it is enabled, and Anthropic's
/// own "where it went" breakdown of the week.
struct WeeklySection: View {
    let report: UsageReport
    let now: Date

    /// Whether the report has anything to show in this section.
    static func hasContent(_ report: UsageReport) -> Bool {
        !report.weeklyLimits.isEmpty || report.extraUsage?.isEnabled == true
            || !(report.weeklyBreakdown?.rows.isEmpty ?? true)
    }

    private var showsExtraUsage: Bool {
        report.extraUsage?.isEnabled == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Weekly limits")

            if !report.weeklyLimits.isEmpty || showsExtraUsage {
                VStack(spacing: 10) {
                    ForEach(report.weeklyLimits) { limit in
                        WeeklyLimitRow(limit: limit, now: now)
                    }
                    if let extraUsage = report.extraUsage, extraUsage.isEnabled {
                        ExtraUsageRow(extraUsage: extraUsage)
                    }
                }
            }

            if let breakdown = report.weeklyBreakdown, !breakdown.rows.isEmpty {
                if !report.weeklyLimits.isEmpty || showsExtraUsage {
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
private struct UsageBarRow: View {
    let title: Text
    let detail: Text
    /// The filled share of the bar, `0...1`.
    let fraction: Double
    /// Decides the color: the accent color, orange at 20 % or less left, red at 5 % or less.
    let percentRemaining: Double
    let valueText: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                title
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                detail
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                valueText
                    .font(.callout)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .tint(UsageTint.color(percentRemaining: percentRemaining))
        }
    }
}

// MARK: - One weekly limit

private struct WeeklyLimitRow: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        UsageBarRow(
            title: Text(title),
            detail: resetCaption,
            fraction: min(1, max(0, limit.percentUsed / 100)),
            percentRemaining: limit.percentRemaining,
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
        case .session:
            String(localized: "5-hour session")
        case .other(let raw):
            raw
        }
    }

    private var percentText: String {
        QuotaFormat.percent(limit.percentUsed, locale: .current)
    }

    private var resetCaption: Text {
        guard let resetsAt = limit.resetsAt else {
            return Text("Reset time unknown")
        }
        guard resetsAt > now else {
            return Text("Waiting for fresh data")
        }
        return Text("Resets \(PopoverFormat.weekdayAndTime(resetsAt))")
    }

    private var accessibilityValue: String {
        let used = String(localized: "\(percentText) used", comment: "VoiceOver: share of a limit already used")
        guard let resetsAt = limit.resetsAt, resetsAt > now else { return used }
        let when = PopoverFormat.spokenWeekdayAndTime(resetsAt)
        return used + ". " + String(localized: "Resets \(when)", comment: "VoiceOver: weekday and time of the reset")
    }
}

// MARK: - Extra usage

/// Pay-as-you-go spending beyond the plan, shown only when the account has it enabled.
private struct ExtraUsageRow: View {
    let extraUsage: ExtraUsage

    var body: some View {
        Group {
            if let fraction {
                UsageBarRow(
                    title: Text("Extra usage"),
                    detail: Text(amountDescription),
                    fraction: fraction,
                    percentRemaining: 100 - fraction * 100,
                    valueText: Text("\(QuotaFormat.percent(fraction * 100, locale: .current)) used")
                )
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Extra usage")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    Text(amountDescription)
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

    /// The share of the monthly limit spent, `0...1`; `nil` without a limit.
    private var fraction: Double? {
        if let percent = extraUsage.percentUsed {
            return min(1, max(0, percent / 100))
        }
        guard let used = extraUsage.usedCreditsMinor, let limit = extraUsage.monthlyLimitMinor, limit > 0 else {
            return nil
        }
        return min(1, max(0, used / limit))
    }

    private var accessibilityValue: String {
        guard let fraction else { return amountDescription }
        let used = String(
            localized: "\(QuotaFormat.percent(fraction * 100, locale: .current)) used",
            comment: "VoiceOver: share of a limit already used")
        return amountDescription + ". " + used
    }

    /// "$12.40 of $50.00", or just "$12.40" without a limit.
    private var amountDescription: String {
        let used = money(extraUsage.usedCreditsMinor ?? 0)
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
        return rows.map { row in
            let color: Color
            if row.key == "other" {
                color = .gray
            } else {
                color = Self.palette[next % Self.palette.count]
                next += 1
            }
            return Segment(id: row.key, name: row.displayName, percent: row.percent, color: color)
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
        let id: String
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
