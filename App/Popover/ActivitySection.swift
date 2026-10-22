import Charts
import QuotaRingCore
import SwiftUI

extension AppModel {
    /// What the Activity section's range picker reads and writes: the model's ``activityRange``, which outlives the
    /// popover's views.
    var activityRangeBinding: Binding<ActivityRange> {
        Binding(get: { self.activityRange }, set: { self.activityRange = $0 })
    }
}

/// Tokens used on this Mac, counted from Claude Code's local transcripts: a segmented range (session, today,
/// 7 days), the total, the top models and projects, and for 7 days a bar chart per day.
///
/// The numbers are approximate and only cover Claude Code on this Mac; they are not the limit (that comes from
/// Anthropic's usage report).
struct ActivitySection: View {
    /// Token totals per range. Empty until the first scan has finished.
    let activity: [ActivityRange: UsageBreakdown]
    /// The last 7 local days, oldest first.
    let daily: [DailyTokens]
    let now: Date
    /// The chosen range. It lives in ``AppModel`` rather than here: the popover's views are made anew every time it
    /// opens, and the choice should stay.
    @Binding var range: ActivityRange

    /// The most rows a list shows.
    private static let listLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The picker is as wide as its labels need; when the header and the picker do not fit side by side (a long
            // translation), the picker moves under the title and takes the full width.
            ViewThatFits(in: .horizontal) {
                HStack {
                    SectionHeader("Activity")
                    Spacer(minLength: 12)
                    rangePicker.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader("Activity")
                    rangePicker
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PopoverMetrics.inset)
        .padding(.vertical, 14)
    }

    private var rangePicker: some View {
        Picker(selection: $range) {
            Text("Session", comment: "Activity range: the current 5-hour session").tag(ActivityRange.session)
            Text("Today", comment: "Activity range: since midnight").tag(ActivityRange.today)
            Text("7 days", comment: "Activity range: the last seven days").tag(ActivityRange.week)
        } label: {
            Text("Time range", comment: "VoiceOver label of the Activity range control")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if activity.isEmpty {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading local activity…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            // All ranges are laid out on top of each other and only the chosen one is visible, so the block keeps the
            // height of the tallest one (the 7-day chart) and the popover does not jump when the range changes.
            ZStack(alignment: .top) {
                ForEach(ActivityRange.allCases) { candidate in
                    rangeContent(candidate)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .opacity(candidate == range ? 1 : 0)
                        .allowsHitTesting(candidate == range)
                        .accessibilityHidden(candidate != range)
                }
            }
        }
    }

    @ViewBuilder
    private func rangeContent(_ candidate: ActivityRange) -> some View {
        if let breakdown = activity[candidate], breakdown.total.total > 0 {
            VStack(alignment: .leading, spacing: 12) {
                TotalView(tokens: breakdown.total.total)
                if candidate == .week, daily.contains(where: { $0.tokens.total > 0 }) {
                    DailyChart(daily: daily, now: now)
                }
                // Model names are short, so that column is capped and projects get the rest of the width; long names
                // in either column are shortened in the middle.
                HStack(alignment: .top, spacing: 16) {
                    if !breakdown.byModel.isEmpty {
                        RankedList(title: "Models", rows: Array(breakdown.byModel.prefix(Self.listLimit)))
                            .frame(maxWidth: 140, alignment: .leading)
                    }
                    if !breakdown.byProject.isEmpty {
                        RankedList(title: "Projects", rows: Array(breakdown.byProject.prefix(Self.listLimit)))
                    }
                }
            }
        } else {
            VStack(spacing: 3) {
                Text("No activity in this period")
                    .font(.callout.weight(.medium))
                Text("Only Claude Code sessions on this Mac are counted.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Total

private struct TotalView: View {
    let tokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(QuotaFormat.tokens(tokens, locale: .current))
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                Text("tokens", comment: "Unit after a total such as 4.2M")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Approximate, from Claude Code on this Mac", comment: "Caption under the total token count")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(PopoverFormat.spokenTokens(tokens)) tokens, approximate, from Claude Code on this Mac")
        )
    }
}

// MARK: - Ranked lists

/// Models or projects, largest first, each with its token count.
private struct RankedList: View {
    let title: LocalizedStringKey
    let rows: [NamedTokens]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(rows) { row in
                    RankedRow(name: row.name, tokens: row.tokens.total)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RankedRow: View {
    let name: String
    let tokens: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(QuotaFormat.tokens(tokens, locale: .current))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .help(name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(Text("\(PopoverFormat.spokenTokens(tokens)) tokens"))
    }
}

// MARK: - 7-day chart

private struct DailyChart: View {
    let daily: [DailyTokens]
    let now: Date

    var body: some View {
        Chart(daily) { day in
            BarMark(
                x: .value("Day", day.day, unit: .day),
                y: .value("Tokens", day.tokens.total),
                width: .ratio(0.62)
            )
            .foregroundStyle(isToday(day.day) ? UsageTint.normal : UsageTint.normal.opacity(0.4))
            .cornerRadius(3)
            .accessibilityLabel(day.day.formatted(.dateTime.weekday(.wide)))
            .accessibilityValue(Text("\(PopoverFormat.spokenTokens(day.tokens.total)) tokens"))
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                    .font(.caption)
            }
        }
        .chartOverlay { proxy in
            // Invisible columns over the bars: hovering one shows that day's number as a tooltip.
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    HStack(spacing: 0) {
                        ForEach(daily) { day in
                            Color.clear
                                .contentShape(Rectangle())
                                .help(tooltip(for: day))
                        }
                    }
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
                }
            }
            .accessibilityHidden(true)
        }
        .frame(height: 66)
        .accessibilityLabel(Text("Tokens per day, last 7 days", comment: "VoiceOver label of the 7-day chart"))
    }

    private func tooltip(for day: DailyTokens) -> String {
        let date = day.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        let tokens = QuotaFormat.tokens(day.tokens.total, locale: .current)
        return String(
            localized: "\(date): \(tokens) tokens", comment: "Tooltip of a bar in the 7-day chart: a date, then a count"
        )
    }

    private func isToday(_ day: Date) -> Bool {
        Calendar.current.isDate(day, inSameDayAs: now)
    }
}

#if DEBUG
    #Preview("Activity, 7 days") {
        ActivitySection(
            activity: DemoData.activity(now: .now), daily: DemoData.daily(now: .now, calendar: .current), now: .now,
            range: .constant(.week)
        )
        .frame(width: PopoverMetrics.width)
    }

    #Preview("Activity, loading") {
        ActivitySection(activity: [:], daily: [], now: .now, range: .constant(.session))
            .frame(width: PopoverMetrics.width)
    }

    #Preview("Activity, none") {
        let empty = UsageBreakdown(total: .zero, byModel: [], byProject: [])
        return ActivitySection(
            activity: [.session: empty, .today: empty, .week: empty], daily: [], now: .now, range: .constant(.session)
        )
        .frame(width: PopoverMetrics.width)
    }
#endif
