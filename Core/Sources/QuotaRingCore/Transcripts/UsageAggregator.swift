import Foundation

public struct NamedTokens: Hashable, Sendable, Identifiable {
    public var name: String
    public var tokens: TokenCounts

    public var id: String { name }

    public init(name: String, tokens: TokenCounts) {
        self.name = name
        self.tokens = tokens
    }
}

public struct UsageBreakdown: Hashable, Sendable {
    public var total: TokenCounts
    /// Grouped by `ModelNames.family`, largest total first.
    public var byModel: [NamedTokens]
    /// Grouped by project name, largest total first.
    public var byProject: [NamedTokens]

    public init(total: TokenCounts, byModel: [NamedTokens], byProject: [NamedTokens]) {
        self.total = total
        self.byModel = byModel
        self.byProject = byProject
    }
}

public struct DailyTokens: Hashable, Sendable, Identifiable {
    /// The start of the calendar day.
    public var day: Date
    public var tokens: TokenCounts

    public var id: Date { day }

    public init(day: Date, tokens: TokenCounts) {
        self.day = day
        self.tokens = tokens
    }
}

/// Totals for the transcript entries returned by `TranscriptScanner`.
public enum UsageAggregator {
    /// Totals for the entries whose timestamp lies in `interval` (both ends included, as `DateInterval.contains`).
    ///
    /// Rows are ordered by total tokens, largest first; equal totals are ordered by name.
    public static func breakdown(_ entries: [TranscriptEntry], in interval: DateInterval) -> UsageBreakdown {
        var total = TokenCounts.zero
        var byModel: [String: TokenCounts] = [:]
        var byProject: [String: TokenCounts] = [:]
        for entry in entries where interval.contains(entry.timestamp) {
            total += entry.tokens
            byModel[ModelNames.family(entry.model), default: .zero] += entry.tokens
            byProject[entry.project, default: .zero] += entry.tokens
        }
        return UsageBreakdown(total: total, byModel: ranked(byModel), byProject: ranked(byProject))
    }

    /// One item per calendar day for the `days` days up to and including the day of `endingAt`, oldest first.
    ///
    /// Days without entries are present with zero tokens; entries outside the window are ignored.
    public static func daily(
        _ entries: [TranscriptEntry], days: Int, endingAt: Date, calendar: Calendar
    ) -> [DailyTokens] {
        guard days > 0 else { return [] }

        let lastDay = calendar.startOfDay(for: endingAt)
        let dayStarts: [Date] = (0..<days).reversed().map { daysBack in
            let shifted = calendar.date(byAdding: .day, value: -daysBack, to: lastDay) ?? lastDay
            return calendar.startOfDay(for: shifted)
        }
        guard let firstDay = dayStarts.first else { return [] }
        // Entries outside [firstDay, windowEnd) are skipped up front; day buckets are looked up exactly below.
        let windowEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? .distantFuture

        var totals: [Date: TokenCounts] = [:]
        for entry in entries where entry.timestamp >= firstDay && entry.timestamp < windowEnd {
            totals[calendar.startOfDay(for: entry.timestamp), default: .zero] += entry.tokens
        }
        return dayStarts.map { DailyTokens(day: $0, tokens: totals[$0] ?? .zero) }
    }

    private static func ranked(_ totals: [String: TokenCounts]) -> [NamedTokens] {
        totals.map { NamedTokens(name: $0.key, tokens: $0.value) }
            .sorted { lhs, rhs in
                let (left, right) = (lhs.tokens.total, rhs.tokens.total)
                return left != right ? left > right : lhs.name < rhs.name
            }
    }
}
