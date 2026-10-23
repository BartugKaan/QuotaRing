import Foundation
import QuotaRingCore

/// Made-up usage for tests. No real account, token or project name appears here.
enum TestData {
    /// A snapshot with a session limit and, optionally, a weekly one.
    ///
    /// - Parameters:
    ///   - sessionUsed: percent of the session limit used.
    ///   - resetsIn: seconds from `now` until the session resets; negative when it has already reset; `nil` for no
    ///     reset time.
    ///   - fetchedAgo: how old the numbers are at `now`.
    static func snapshot(
        now: Date,
        sessionUsed: Double = 40,
        resetsIn: TimeInterval? = 7_200,
        fetchedAgo: TimeInterval = 30,
        source: SnapshotSource = .claudeCodeCache,
        withWeekly: Bool = true
    ) -> UsageSnapshot {
        var limits = [
            UsageLimit(
                kind: .session, percentUsed: sessionUsed, resetsAt: resetsIn.map { now.addingTimeInterval($0) },
                isActive: true)
        ]
        if withWeekly {
            limits.append(
                UsageLimit(kind: .weeklyAll, percentUsed: 18, resetsAt: now.addingTimeInterval(3 * 86_400)))
        }
        return UsageSnapshot(
            report: UsageReport(limits: limits), fetchedAt: now.addingTimeInterval(-fetchedAgo), source: source)
    }

    /// A snapshot without any session limit.
    static func snapshotWithoutSession(now: Date) -> UsageSnapshot {
        UsageSnapshot(
            report: UsageReport(limits: [UsageLimit(kind: .weeklyAll, percentUsed: 10)]),
            fetchedAt: now.addingTimeInterval(-10), source: .claudeCodeCache)
    }
}
