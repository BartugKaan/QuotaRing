import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct SnapshotLogicTests {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    private func snapshot(
        session: UsageLimit?,
        fetchedAt: Date? = nil,
        source: SnapshotSource = .live
    ) -> UsageSnapshot {
        UsageSnapshot(
            report: UsageReport(limits: session.map { [$0] } ?? []),
            fetchedAt: fetchedAt ?? now,
            source: source
        )
    }

    private func snapshot(fetchedAt: TimeInterval, source: SnapshotSource) -> UsageSnapshot {
        snapshot(session: nil, fetchedAt: Date(timeIntervalSince1970: fetchedAt), source: source)
    }

    @Test func sessionResetsWhenResetTimePassed() {
        let limit = UsageLimit(kind: .session, percentUsed: 83, resetsAt: now.addingTimeInterval(-1))
        let effective = snapshot(session: limit).session(at: now)
        #expect(effective?.percentUsed == 0)
        #expect(effective?.resetsAt == nil)
        #expect(effective?.kind == .session)
        #expect(effective?.id == "session")

        // Exactly at the reset instant counts as reset (`resetsAt <= now`).
        let atReset = UsageLimit(kind: .session, percentUsed: 83, resetsAt: now)
        #expect(snapshot(session: atReset).session(at: now)?.percentUsed == 0)
        #expect(snapshot(session: atReset).session(at: now)?.resetsAt == nil)
    }

    @Test func sessionUnchangedBeforeReset() {
        let limit = UsageLimit(kind: .session, percentUsed: 83, resetsAt: now.addingTimeInterval(60))
        #expect(snapshot(session: limit).session(at: now) == limit)

        // No reset time known: nothing to expire.
        let open = UsageLimit(kind: .session, percentUsed: 12)
        #expect(snapshot(session: open).session(at: now) == open)

        // No session limit at all.
        #expect(snapshot(session: nil).session(at: now) == nil)
    }

    @Test func effectiveLimitIsFreshOnceResetTimePassed() {
        let weekly = UsageLimit(
            kind: .weeklyScoped, group: "weekly", percentUsed: 62, resetsAt: now.addingTimeInterval(-1),
            scopeName: "Opus", severity: "high", isActive: true)
        let effective = weekly.effective(at: now)
        #expect(effective.percentUsed == 0)
        #expect(effective.resetsAt == nil)
        // Everything else is preserved.
        #expect(effective.id == weekly.id)
        #expect(effective.kind == .weeklyScoped)
        #expect(effective.scopeName == "Opus")
        #expect(effective.group == "weekly")
        #expect(effective.severity == "high")
        #expect(effective.isActive)

        // Exactly at the reset instant counts as reset.
        let atReset = UsageLimit(kind: .weeklyAll, percentUsed: 41, resetsAt: now)
        #expect(atReset.effective(at: now).percentUsed == 0)
        #expect(atReset.effective(at: now).resetsAt == nil)
    }

    @Test func effectiveLimitUnchangedBeforeResetOrWithoutResetTime() {
        let pending = UsageLimit(kind: .weeklyAll, percentUsed: 41, resetsAt: now.addingTimeInterval(60))
        #expect(pending.effective(at: now) == pending)

        let open = UsageLimit(kind: .weeklyAll, percentUsed: 41)
        #expect(open.effective(at: now) == open)
    }

    @Test func staleness() {
        let fresh = snapshot(session: nil, fetchedAt: now.addingTimeInterval(-300))
        #expect(!fresh.isStale(at: now, maxAge: 300))

        let old = snapshot(session: nil, fetchedAt: now.addingTimeInterval(-301))
        #expect(old.isStale(at: now, maxAge: 300))
    }

    @Test func freshestPicksNewest() {
        let older = snapshot(fetchedAt: 1_000, source: .claudeCodeCache)
        let newer = snapshot(fetchedAt: 2_000, source: .live)
        #expect(SnapshotSelector.freshest([older, newer]) == newer)
        #expect(SnapshotSelector.freshest([newer, older]) == newer)

        let newestCache = snapshot(fetchedAt: 3_000, source: .claudeCodeCache)
        #expect(SnapshotSelector.freshest([nil, newer, newestCache, older]) == newestCache)
    }

    @Test func freshestTiePrefersLive() {
        let cache = snapshot(fetchedAt: 2_000, source: .claudeCodeCache)
        let live = snapshot(fetchedAt: 2_000, source: .live)
        #expect(SnapshotSelector.freshest([cache, live]) == live)
        #expect(SnapshotSelector.freshest([live, cache]) == live)
    }

    @Test func freshestAllNil() {
        #expect(SnapshotSelector.freshest([nil, nil]) == nil)
        #expect(SnapshotSelector.freshest([]) == nil)
    }

    // MARK: - Window state

    @Test func windowStateDistinguishesResetPassedFromNoWindow() {
        let ahead = now.addingTimeInterval(600)
        #expect(UsageLimit(kind: .session, percentUsed: 30, resetsAt: ahead).windowState(at: now) == .resetsAt(ahead))
        #expect(
            UsageLimit(kind: .session, percentUsed: 30, resetsAt: now.addingTimeInterval(-1)).windowState(at: now)
                == .resetPassed)
        // Exactly at the reset instant counts as reset, like `effective(at:)`.
        #expect(UsageLimit(kind: .session, percentUsed: 30, resetsAt: now).windowState(at: now) == .resetPassed)
        // A reset that passed with 0 % used is still "waiting for fresh data", not "no window".
        #expect(
            UsageLimit(kind: .session, percentUsed: 0, resetsAt: now.addingTimeInterval(-1)).windowState(at: now)
                == .resetPassed)
        #expect(UsageLimit(kind: .session, percentUsed: 12, resetsAt: nil).windowState(at: now) == .resetTimeUnknown)
        #expect(UsageLimit(kind: .session, percentUsed: 0, resetsAt: nil).windowState(at: now) == .notStarted)
    }

    @Test func sessionHasResetOnlyAfterItsResetTime() {
        let passed = UsageLimit(kind: .session, percentUsed: 80, resetsAt: now.addingTimeInterval(-60))
        let ahead = UsageLimit(kind: .session, percentUsed: 80, resetsAt: now.addingTimeInterval(60))
        let notStarted = UsageLimit(kind: .session, percentUsed: 0)
        #expect(snapshot(session: passed).sessionHasReset(at: now))
        #expect(!snapshot(session: ahead).sessionHasReset(at: now))
        #expect(!snapshot(session: notStarted).sessionHasReset(at: now))
        #expect(!snapshot(session: nil).sessionHasReset(at: now))
    }

    // MARK: - Generic titles

    @Test func genericTitleHumanizesTheKind() {
        #expect(UsageLimit(kind: .other("monthly_pool"), percentUsed: 1).genericTitle == "Monthly pool")
        #expect(UsageLimit(kind: .other("seven_day-cowork"), percentUsed: 1).genericTitle == "Seven day cowork")
        #expect(UsageLimit(kind: .other("  daily__api "), percentUsed: 1).genericTitle == "Daily api")
        #expect(
            UsageLimit(kind: .other("monthly_pool"), percentUsed: 1, scopeName: "Opus").genericTitle
                == "Monthly pool · Opus")
        #expect(UsageLimit(kind: .other("_"), percentUsed: 1, scopeName: "Opus").genericTitle == "Opus")
        #expect(UsageLimit(kind: .other(""), percentUsed: 1, scopeName: " ").genericTitle == nil)
    }

    // MARK: - Plausible fetch dates

    @Test func fetchDateMoreThanFiveMinutesAheadIsImplausible() {
        #expect(UsageSnapshot.maxFutureSkew == 300)
        #expect(snapshot(session: nil, fetchedAt: now.addingTimeInterval(-86_400)).hasPlausibleFetchDate(at: now))
        #expect(snapshot(session: nil, fetchedAt: now.addingTimeInterval(300)).hasPlausibleFetchDate(at: now))
        #expect(!snapshot(session: nil, fetchedAt: now.addingTimeInterval(301)).hasPlausibleFetchDate(at: now))
        #expect(!snapshot(session: nil, fetchedAt: now.addingTimeInterval(86_400 * 365)).hasPlausibleFetchDate(at: now))
    }

    // MARK: - Candidates

    @Test func candidatesPreferTheFreshest() {
        var candidates = SnapshotCandidates(persisted: snapshot(fetchedAt: 1_000, source: .claudeCodeCache))
        #expect(candidates.freshest?.fetchedAt == Date(timeIntervalSince1970: 1_000))

        let changed = candidates.recordCacheRead(snapshot(fetchedAt: 2_000, source: .claudeCodeCache))
        #expect(changed)
        #expect(candidates.freshest == candidates.cached)

        candidates.recordLive(snapshot(fetchedAt: 3_000, source: .live))
        #expect(candidates.freshest == candidates.live)
    }

    @Test func candidatesIgnoreAnOlderOrUnchangedCacheRead() {
        var candidates = SnapshotCandidates()
        let newer = snapshot(fetchedAt: 2_000, source: .claudeCodeCache)
        let first = candidates.recordCacheRead(newer)
        let older = candidates.recordCacheRead(snapshot(fetchedAt: 1_000, source: .claudeCodeCache))
        let same = candidates.recordCacheRead(newer)
        let none = candidates.recordCacheRead(nil)
        #expect(first)
        #expect(!older)
        #expect(!same)
        #expect(!none)
        #expect(candidates.cached == newer)
    }

    @Test func persistedLosesATieToTheFullCachedCopy() {
        var candidates = SnapshotCandidates(persisted: snapshot(fetchedAt: 2_000, source: .claudeCodeCache))
        var full = snapshot(fetchedAt: 2_000, source: .claudeCodeCache)
        full.report.extraUsage = ExtraUsage(isEnabled: true, usedCreditsMinor: 120)
        candidates.recordCacheRead(full)
        #expect(candidates.freshest == full)
    }

    @Test func accountMismatchDropsEverythingOnce() {
        var candidates = SnapshotCandidates(persisted: snapshot(fetchedAt: 1_000, source: .live))
        candidates.recordCacheRead(snapshot(fetchedAt: 2_000, source: .claudeCodeCache))
        candidates.recordLive(snapshot(fetchedAt: 3_000, source: .live))

        // The first report: the previous account's numbers, Live included, must not stay on screen.
        let began = candidates.recordAccountMismatch()
        #expect(began)
        #expect(candidates.persisted == nil)
        #expect(candidates.cached == nil)
        #expect(candidates.live == nil)
        #expect(candidates.freshest == nil)

        // While the mismatch lasts, a Live snapshot fetched since (with the signed-in account's login) stays.
        let current = snapshot(fetchedAt: 4_000, source: .live)
        candidates.recordLive(current)
        let beganAgain = candidates.recordAccountMismatch()
        #expect(!beganAgain)
        #expect(candidates.freshest == current)

        // A good cache read ends the mismatch; a later one is a new account change and drops again.
        candidates.recordCacheRead(nil)
        let changedAccountAgain = candidates.recordAccountMismatch()
        #expect(changedAccountAgain)
        #expect(candidates.live == nil)
    }
}
