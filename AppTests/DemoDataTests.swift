import Foundation
import QuotaRingCore
import Testing

@Suite struct DemoDataTests {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    // MARK: - The snapshot

    @Test func theSnapshotIsMarkedAsDemoAndLooksLikeTheDocumentedScreenshot() throws {
        let snapshot = DemoData.snapshot(now: now)

        #expect(snapshot.source == .demo)
        let session = try #require(snapshot.report.session)
        #expect(session.percentUsed == 28)
        #expect(session.percentRemaining == 72)
        #expect(session.isActive)
        #expect(snapshot.report.weeklyLimits.map(\.percentUsed) == [41, 12])
        #expect(snapshot.report.weeklyLimits.last?.scopeName == "Fable")
        #expect(snapshot.report.extraUsage?.isEnabled == false)
    }

    @Test func theSessionCountdownReadsTwoHoursFourteenRightAfterLaunch() throws {
        let snapshot = DemoData.snapshot(now: now)
        let resetsAt = try #require(snapshot.report.session?.resetsAt)

        #expect(
            QuotaFormat.countdown(to: resetsAt, from: now, locale: Locale(identifier: "en_US")) == "2h 14m")
        #expect(
            QuotaFormat.countdown(to: resetsAt, from: now.addingTimeInterval(20), locale: Locale(identifier: "en_US"))
                == "2h 14m")
    }

    @Test func theSnapshotIsFreshAndItsResetsAreInTheFuture() throws {
        let snapshot = DemoData.snapshot(now: now)

        #expect(snapshot.fetchedAt < now)
        #expect(!snapshot.isStale(at: now, maxAge: 600))
        #expect(!snapshot.sessionHasReset(at: now))
        for limit in snapshot.report.limits {
            #expect(try #require(limit.resetsAt) > now)
            #expect((0...100).contains(limit.percentUsed))
        }
        // It keeps its offsets whenever it is built.
        let later = DemoData.snapshot(now: now.addingTimeInterval(86_400))
        #expect(later.fetchedAt.timeIntervalSince(now) == snapshot.fetchedAt.timeIntervalSince(now) + 86_400)
    }

    @Test func limitIdentifiersAreUnique() {
        let ids = DemoData.snapshot(now: now).report.limits.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func theWeeklyBreakdownAddsUpToAWhole() throws {
        let breakdown = try #require(DemoData.snapshot(now: now).report.weeklyBreakdown)

        #expect(breakdown.rows.map(\.percent).reduce(0, +) == 100)
        #expect(Set(breakdown.rows.map(\.key)).count == breakdown.rows.count)
        let windowStart = try #require(breakdown.windowStartedAt)
        let asOf = try #require(breakdown.asOf)
        #expect(windowStart < asOf)
        #expect(asOf <= now)
    }

    @Test func aDemoSnapshotIsNeverWrittenToDisk() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaRingAppTests-demo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LastSnapshotStore(fileURL: folder.appendingPathComponent("last-snapshot.json"))

        try store.save(DemoData.snapshot(now: now), configDirectory: folder)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: - Activity

    @Test func everyRangeHasActivityWithConsistentTotals() throws {
        let activity = DemoData.activity(now: now)

        #expect(Set(activity.keys) == Set(ActivityRange.allCases))
        for (range, breakdown) in activity {
            #expect(breakdown.total.total > 0, "\(range) is empty")
            // The models add up to the total.
            let byModel = breakdown.byModel.reduce(TokenCounts.zero) { $0 + $1.tokens }
            #expect(byModel == breakdown.total)
            // The project shares never claim more than the whole (rounding down may leave a little over).
            let byProject = breakdown.byProject.reduce(TokenCounts.zero) { $0 + $1.tokens }
            #expect(byProject.total <= breakdown.total.total)
            #expect(byProject.total * 100 >= breakdown.total.total * 95)
            #expect(Set(breakdown.byModel.map(\.name)).count == breakdown.byModel.count)
            #expect(Set(breakdown.byProject.map(\.name)).count == breakdown.byProject.count)
        }
    }

    @Test func longerRangesHoldMoreThanShorterOnes() throws {
        let activity = DemoData.activity(now: now)
        let session = try #require(activity[.session]).total.total
        let today = try #require(activity[.today]).total.total
        let week = try #require(activity[.week]).total.total

        #expect(session < today)
        #expect(today < week)
    }

    @Test func rowsAreRankedLargestFirst() throws {
        for breakdown in DemoData.activity(now: now).values {
            let models = breakdown.byModel.map(\.tokens.total)
            #expect(models == models.sorted(by: >))
            let projects = breakdown.byProject.map(\.tokens.total)
            #expect(projects == projects.sorted(by: >))
        }
    }

    @Test func projectNamesAreMadeUp() {
        // Names of real projects must never reach a screenshot (see the README on `--demo`).
        let names = DemoData.activity(now: now).values.flatMap { $0.byProject.map(\.name) }
        let allowed: Set<String> = ["quotaring", "garden-planner", "dotfiles", "recipe-box", "blog", "scratch"]
        #expect(Set(names).isSubset(of: allowed))
    }

    // MARK: - Daily totals

    @Test func sevenConsecutiveDaysEndingTodayOldestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Istanbul"))
        let daily = DemoData.daily(now: now, calendar: calendar)

        #expect(daily.count == 7)
        #expect(daily.last?.day == calendar.startOfDay(for: now))
        for (older, newer) in zip(daily, daily.dropFirst()) {
            #expect(calendar.date(byAdding: .day, value: 1, to: older.day) == newer.day)
        }
        for day in daily {
            #expect(day.day == calendar.startOfDay(for: day.day))
            #expect(day.tokens.total > 0)
            #expect(day.tokens.input >= 0 && day.tokens.output >= 0)
            #expect(day.tokens.cacheWrite >= 0 && day.tokens.cacheRead >= 0)
        }
    }

    @Test func eachDaysPartsAddUpToItsRoundTotal() {
        let daily = DemoData.daily(now: now, calendar: Calendar(identifier: .gregorian))
        let expectedThousands = [1_840, 3_120, 640, 2_950, 2_410, 1_070, 3_480]

        #expect(daily.map { $0.tokens.total } == expectedThousands.map { $0 * 1_000 })
    }

    @Test func theDaysFollowTheCalendarAcrossAClockChange() throws {
        // The night the clocks went forward in New York (2026-03-08) has 23 hours; days must still be whole days.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let afterChange = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))

        let daily = DemoData.daily(now: afterChange, calendar: calendar)

        #expect(daily.count == 7)
        let starts = daily.map { calendar.dateComponents([.year, .month, .day, .hour], from: $0.day) }
        #expect(starts.map(\.day) == [3, 4, 5, 6, 7, 8, 9])
        #expect(starts.allSatisfy { $0.hour == 0 })
    }
}
