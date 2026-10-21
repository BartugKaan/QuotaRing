import Foundation
import Testing

@testable import QuotaRingCore

private func date(_ text: String) throws -> Date {
    try #require(FlexibleDate.parse(text))
}

private func entry(
    _ key: String,
    at timestamp: String,
    model: String = "claude-opus-4-8",
    project: String = "alpha",
    input: Int = 0,
    output: Int = 0,
    cacheWrite: Int = 0,
    cacheRead: Int = 0
) throws -> TranscriptEntry {
    TranscriptEntry(
        dedupeKey: key,
        timestamp: try date(timestamp),
        model: model,
        project: project,
        tokens: TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead))
}

private func istanbulCalendar() throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/Istanbul"))
    return calendar
}

@Suite struct UsageAggregatorTests {
    // MARK: breakdown

    @Test func breakdownFiltersInterval() throws {
        let entries = [
            try entry("before", at: "2026-10-20T09:59:59Z", input: 1_000),
            try entry("start", at: "2026-10-20T10:00:00Z", input: 1),
            try entry("inside", at: "2026-10-20T11:00:00Z", output: 20),
            try entry("end", at: "2026-10-20T12:00:00Z", cacheRead: 300),
            try entry("after", at: "2026-10-20T12:00:01Z", cacheWrite: 4_000),
        ]
        let interval = DateInterval(start: try date("2026-10-20T10:00:00Z"), end: try date("2026-10-20T12:00:00Z"))

        let breakdown = UsageAggregator.breakdown(entries, in: interval)

        // The interval is closed at both ends, like `DateInterval.contains`.
        #expect(breakdown.total == TokenCounts(input: 1, output: 20, cacheWrite: 0, cacheRead: 300))
        #expect(breakdown.byModel.map(\.tokens.total) == [321])
    }

    @Test func breakdownOfNothingIsEmpty() throws {
        let interval = DateInterval(start: try date("2026-10-20T10:00:00Z"), duration: 3_600)
        let empty = UsageAggregator.breakdown([], in: interval)
        #expect(empty == UsageBreakdown(total: .zero, byModel: [], byProject: []))

        let outside = UsageAggregator.breakdown([try entry("x", at: "2026-01-01T00:00:00Z", input: 5)], in: interval)
        #expect(outside == empty)
    }

    @Test func breakdownGroupsByModelFamilyAndProject() throws {
        let entries = [
            try entry("a", at: "2026-10-20T10:00:00Z", model: "claude-opus-4-5-20251101", project: "alpha", input: 100),
            try entry("b", at: "2026-10-20T10:01:00Z", model: "claude-opus-4-5", project: "beta", output: 50),
            try entry("c", at: "2026-10-20T10:02:00Z", model: "claude-haiku-4-5-20251001", project: "alpha", input: 10),
            try entry("d", at: "2026-10-20T10:03:00Z", model: "claude-opus-4-8", project: "alpha", cacheRead: 1_000),
            try entry("e", at: "2026-10-20T10:04:00Z", model: "gpt-x", project: "Unknown", output: 5),
        ]
        let interval = DateInterval(start: try date("2026-10-20T00:00:00Z"), duration: 86_400)

        let breakdown = UsageAggregator.breakdown(entries, in: interval)

        #expect(breakdown.total.total == 1_165)
        // Two snapshots of Opus 4.5 collapse into one row; rows are ordered by total, largest first.
        #expect(breakdown.byModel.map(\.name) == ["Opus 4.8", "Opus 4.5", "Haiku 4.5", "gpt-x"])
        #expect(breakdown.byModel.map(\.tokens.total) == [1_000, 150, 10, 5])
        #expect(breakdown.byProject.map(\.name) == ["alpha", "beta", "Unknown"])
        #expect(breakdown.byProject.map(\.tokens.total) == [1_110, 50, 5])
        #expect(breakdown.byProject.map(\.id) == ["alpha", "beta", "Unknown"])
    }

    @Test func tiesAreOrderedByNameAscending() throws {
        let entries = [
            try entry("1", at: "2026-10-20T10:00:00Z", model: "claude-sonnet-4-5", project: "zeta", input: 7),
            try entry("2", at: "2026-10-20T10:00:00Z", model: "claude-haiku-4-5", project: "alpha", input: 7),
            try entry("3", at: "2026-10-20T10:00:00Z", model: "claude-opus-4-8", project: "mid", input: 7),
        ]
        let interval = DateInterval(start: try date("2026-10-20T00:00:00Z"), duration: 86_400)

        let breakdown = UsageAggregator.breakdown(entries, in: interval)

        #expect(breakdown.byModel.map(\.name) == ["Haiku 4.5", "Opus 4.8", "Sonnet 4.5"])
        #expect(breakdown.byProject.map(\.name) == ["alpha", "mid", "zeta"])
    }

    // MARK: daily

    @Test func groupsByLocalDay() throws {
        let calendar = try istanbulCalendar()
        // Istanbul is UTC+3: 20:59Z is 23:59 on the 20th, 21:01Z is 00:01 on the 21st.
        let entries = [
            try entry("late", at: "2026-10-20T20:59:00Z", input: 100),
            try entry("early", at: "2026-10-20T21:01:00Z", input: 7),
            try entry("also-early", at: "2026-10-21T08:00:00Z", output: 3),
        ]

        let daily = UsageAggregator.daily(
            entries, days: 3, endingAt: try date("2026-10-21T12:00:00Z"), calendar: calendar)

        #expect(daily.count == 3)
        let twentieth = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20)))
        let twentyFirst = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21)))
        #expect(
            daily.map(\.day) == [
                try #require(calendar.date(byAdding: .day, value: -1, to: twentieth)), twentieth, twentyFirst,
            ])
        #expect(daily.map(\.tokens.total) == [0, 100, 10])
        // Local midnight of the 20th is 21:00Z on the 19th.
        #expect(daily[1].day == (try date("2026-10-19T21:00:00Z")))
    }

    @Test func dailyIsZeroFilled() throws {
        let calendar = try istanbulCalendar()
        let entries = [
            try entry("a", at: "2026-10-15T09:00:00Z", input: 1),
            try entry("b", at: "2026-10-17T09:00:00Z", output: 2),
            try entry("c", at: "2026-10-21T09:00:00Z", cacheRead: 4),
            // Outside the 7-day window on either side.
            try entry("old", at: "2026-10-14T20:59:00Z", input: 900),
            try entry("future", at: "2026-10-21T21:00:00Z", input: 900),
        ]

        let daily = UsageAggregator.daily(
            entries, days: 7, endingAt: try date("2026-10-21T12:00:00Z"), calendar: calendar)

        #expect(daily.count == 7)
        #expect(daily.map(\.tokens.total) == [1, 0, 2, 0, 0, 0, 4])
        #expect(daily == daily.sorted { $0.day < $1.day })
        #expect(Set(daily.map(\.day)).count == 7)
        #expect(daily.allSatisfy { calendar.startOfDay(for: $0.day) == $0.day })
        #expect(daily.last?.day == calendar.startOfDay(for: try date("2026-10-21T12:00:00Z")))
        #expect(daily.map(\.id) == daily.map(\.day))
    }

    @Test func dailyWithNoEntriesIsAllZeros() throws {
        let daily = UsageAggregator.daily(
            [], days: 7, endingAt: try date("2026-10-21T12:00:00Z"), calendar: try istanbulCalendar())
        #expect(daily.count == 7)
        #expect(daily.allSatisfy { $0.tokens == .zero })
    }

    @Test func dailyWithNonPositiveDaysIsEmpty() throws {
        let now = try date("2026-10-21T12:00:00Z")
        #expect(UsageAggregator.daily([], days: 0, endingAt: now, calendar: try istanbulCalendar()).isEmpty)
        #expect(UsageAggregator.daily([], days: -3, endingAt: now, calendar: try istanbulCalendar()).isEmpty)
    }

    @Test func dailyHasOneBucketPerCalendarDayAcrossDaylightSavingChanges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        // US clocks fall back on 2026-11-01 (a 25-hour day) and spring forward on 2026-03-08 (a 23-hour day).
        let fall = UsageAggregator.daily(
            [try entry("x", at: "2026-11-01T12:00:00Z", input: 1)],
            days: 4, endingAt: try date("2026-11-02T12:00:00Z"), calendar: calendar)
        #expect(fall.count == 4)
        #expect(fall.map(\.tokens.total) == [0, 0, 1, 0])
        #expect(Set(fall.map(\.day)).count == 4)

        let spring = UsageAggregator.daily(
            [try entry("y", at: "2026-03-08T12:00:00Z", input: 1)],
            days: 4, endingAt: try date("2026-03-09T12:00:00Z"), calendar: calendar)
        #expect(spring.count == 4)
        #expect(spring.map(\.tokens.total) == [0, 0, 1, 0])
        #expect(spring.allSatisfy { calendar.startOfDay(for: $0.day) == $0.day })
    }
}
