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

/// Where a limit's window stands at a point in time, for the caption next to it.
public enum LimitWindowState: Equatable, Sendable {
    /// The window resets at this time, which is still ahead.
    case resetsAt(Date)
    /// The reset time has passed: the old percentage no longer applies and no newer reading has arrived yet.
    case resetPassed
    /// Usage is reported, but not when the window resets.
    case resetTimeUnknown
    /// Nothing is used and there is no reset time: no window has started yet (one starts with the next use).
    case notStarted
}

extension UsageLimit {
    /// Where this limit's window stands at `now`. Call it on the limit as fetched, not on
    /// ``effective(at:)``, which has already dropped a reset time that passed.
    public func windowState(at now: Date) -> LimitWindowState {
        if let resetsAt {
            return resetsAt > now ? .resetsAt(resetsAt) : .resetPassed
        }
        return percentUsed > 0 ? .resetTimeUnknown : .notStarted
    }

    /// A title for a limit of a kind QuotaRing has no name for (``LimitKind/other(_:)``): the endpoint's kind in plain
    /// words, for example `monthly_pool` becomes "Monthly pool", followed by the scope's name when there is one
    /// ("Monthly pool · Opus"). `nil` when neither says anything.
    public var genericTitle: String? {
        let words = kind.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let kindTitle = words.isEmpty ? nil : words.prefix(1).uppercased() + words.dropFirst()
        let scope = scopeName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch (kindTitle, scope) {
        case (let kindTitle?, let scope?): return kindTitle + " · " + scope
        case (let kindTitle?, nil): return kindTitle
        case (nil, let scope?): return scope
        case (nil, nil): return nil
        }
    }
}

extension UsageSnapshot {
    /// How far ahead of the local clock a `fetchedAt` may lie before the snapshot counts as broken. A few minutes of
    /// clock difference are normal; a date far in the future would make the snapshot look fresh for that long and keep
    /// every real update (which is older) from replacing it.
    public static let maxFutureSkew: TimeInterval = 300

    /// Whether `fetchedAt` is believable at `now`: at most ``maxFutureSkew`` ahead.
    public func hasPlausibleFetchDate(at now: Date) -> Bool {
        fetchedAt.timeIntervalSince(now) <= Self.maxFutureSkew
    }

    /// The session limit as it should be shown at `now` (see ``UsageLimit/effective(at:)``).
    public func session(at now: Date) -> UsageLimit? {
        report.session?.effective(at: now)
    }

    /// Whether the session window this snapshot describes has already reset at `now` (its reset time passed).
    public func sessionHasReset(at now: Date) -> Bool {
        report.session?.windowState(at: now) == .resetPassed
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

/// The snapshots that may be shown, with the rules for replacing and dropping them: the one saved at the end of the
/// last run, the latest from Claude Code's cache and the latest from Live mode.
public struct SnapshotCandidates: Equatable, Sendable {
    public private(set) var persisted: UsageSnapshot?
    public private(set) var cached: UsageSnapshot?
    public private(set) var live: UsageSnapshot?
    /// Whether the last cache read found an entry of an account other than the signed-in one.
    private var isCacheFromAnotherAccount = false

    public init(persisted: UsageSnapshot? = nil) {
        self.persisted = persisted
    }

    /// The snapshot to show: the freshest. On a tie a Live one wins, then the cached copy beats the persisted one (which
    /// has no extra-usage amounts).
    public var freshest: UsageSnapshot? {
        SnapshotSelector.freshest([cached, live, persisted])
    }

    /// Records a successful read of Claude Code's cache; `nil` means the file has no usage entry. An entry older than
    /// the one already held is ignored (an out-of-order read). Returns whether the cached snapshot changed.
    @discardableResult
    public mutating func recordCacheRead(_ snapshot: UsageSnapshot?) -> Bool {
        isCacheFromAnotherAccount = false
        guard let snapshot else { return false }
        if let cached, snapshot.fetchedAt < cached.fetchedAt { return false }
        guard snapshot != cached else { return false }
        cached = snapshot
        return true
    }

    /// Records a snapshot from the Live endpoint.
    public mutating func recordLive(_ snapshot: UsageSnapshot) {
        live = snapshot
    }

    /// Records that Claude Code's cache belongs to an account other than the signed-in one: the account changed.
    ///
    /// The first such report drops every snapshot, including the Live one, which was fetched with the previous account's
    /// login; nothing of the previous account may stay on screen or be saved again. While the mismatch lasts (Claude
    /// Code may rewrite the file several times before it caches the new account's usage), later reports drop nothing
    /// more: a Live snapshot fetched in the meantime was fetched with the signed-in account's login.
    ///
    /// - Returns: `true` when this report began a mismatch. The caller then also forgets the previous account's Live
    ///   back-off and deletes the saved snapshot.
    public mutating func recordAccountMismatch() -> Bool {
        guard !isCacheFromAnotherAccount else { return false }
        isCacheFromAnotherAccount = true
        persisted = nil
        cached = nil
        live = nil
        return true
    }
}
