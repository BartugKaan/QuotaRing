import Foundation

extension UsageLimit {
    /// The limit as it should be shown at `now`.
    ///
    /// A limit only knows its usage as of when it was fetched. Once its reset time has passed the old percentage no
    /// longer applies, so a fresh window is returned: `percentUsed` 0 and no reset time, everything else unchanged. A
    /// limit without a reset time, or one that resets later, is returned as it is.
    public func effective(at now: Date) -> UsageLimit {
        guard let resetsAt, resetsAt <= now else { return self }
        var fresh = self
        fresh.percentUsed = 0
        fresh.resetsAt = nil
        return fresh
    }
}

extension UsageSnapshot {
    /// The session limit as it should be shown at `now` (see ``UsageLimit/effective(at:)``).
    public func session(at now: Date) -> UsageLimit? {
        report.session?.effective(at: now)
    }

    /// Whether the snapshot is older than `maxAge` seconds at `now`.
    public func isStale(at now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(fetchedAt) > maxAge
    }
}

/// Chooses which of several snapshots to display.
public enum SnapshotSelector {
    /// The snapshot with the latest `fetchedAt`, ignoring `nil` candidates. A tie goes to a ``SnapshotSource/live``
    /// snapshot, then to the earlier candidate.
    public static func freshest(_ candidates: [UsageSnapshot?]) -> UsageSnapshot? {
        var best: UsageSnapshot?
        for candidate in candidates.compactMap({ $0 }) {
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.fetchedAt > current.fetchedAt
                || (candidate.fetchedAt == current.fetchedAt && candidate.source == .live && current.source != .live)
            {
                best = candidate
            }
        }
        return best
    }
}
