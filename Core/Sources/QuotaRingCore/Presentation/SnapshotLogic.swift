import Foundation

extension UsageSnapshot {
    /// The session limit as it should be shown at `now`.
    ///
    /// A snapshot only knows the session as of when it was fetched. Once the session's reset time has passed the old
    /// percentage no longer applies, so the limit is returned as a fresh window: `percentUsed` 0 and no reset time.
    public func session(at now: Date) -> UsageLimit? {
        guard var session = report.session else { return nil }
        if let resetsAt = session.resetsAt, resetsAt <= now {
            session.percentUsed = 0
            session.resetsAt = nil
        }
        return session
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
