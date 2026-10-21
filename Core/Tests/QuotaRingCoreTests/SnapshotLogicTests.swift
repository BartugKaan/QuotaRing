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
}
