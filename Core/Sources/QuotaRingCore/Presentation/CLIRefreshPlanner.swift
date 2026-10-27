import Foundation

/// Why auto-refresh turned itself off. Remembered until the user turns it on again.
public enum CLISafetyStop: String, Equatable, Sendable, CaseIterable {
    /// A run's result reported model turns, cost or tokens: `/usage` went to the model and spent usage.
    case modelCall
    /// ``RefreshPlanner/unverifiedRunLimit`` runs in a row exited normally with output QuotaRing could not check, so
    /// it could not confirm the runs were free.
    case unverifiableOutput
}

/// What QuotaRing found when it read Claude Code's cache right after a run that reported success.
public enum CLICacheReadResult: Equatable, Sendable {
    /// The file was read; `fetchedAt` is when its usage entry was fetched, `nil` when it has none.
    case read(fetchedAt: Date?)
    /// The file could not be used.
    case failed(CacheReadError)
    /// Another Claude config directory was chosen while it was read: the run no longer applies.
    case configDirectoryChanged
}

/// What to do with a finished run.
public enum CLIRunResolution: Equatable, Sendable {
    /// Record this outcome: back-off, status and, if it calls for it, the safety switch-off.
    case apply(CLIRefreshOutcome)
    /// Drop the run: it says nothing about Claude Code any more.
    case abandon
}

/// The safety switch-off after a run, and the updated count of unverifiable runs in a row.
public struct CLISafetyCheck: Equatable, Sendable {
    public var unverifiedRuns: Int
    /// Set when auto-refresh must turn itself off.
    public var stop: CLISafetyStop?

    public init(unverifiedRuns: Int, stop: CLISafetyStop?) {
        self.unverifiedRuns = unverifiedRuns
        self.stop = stop
    }
}

/// What the UI shows about refreshing through Claude Code ("auto-refresh").
public enum CLIRefreshStatus: Equatable, Sendable {
    /// Turned off (the default), or the app runs in demo mode.
    case off
    /// On and fine. `lastRun` is the start of the last successful run, `nil` before the first.
    case ok(lastRun: Date?)
    /// A run is under way.
    case running
    /// No usable `claude` was found, or the file found is not Claude Code.
    case notFound
    /// Claude Code was found at `path` (version `version`), but it is too old for auto-refresh, and no newer one was.
    case unsupportedVersion(path: String?, version: String?)
    /// Claude Code is not signed in.
    case notLoggedIn
    /// The last run failed for this reason; it is retried with back-off.
    case failed(CLIRefreshFailure)
    /// The feature turned itself off for this reason (see ``CLISafetyStop``).
    case disabledForSafety(CLISafetyStop)

    /// Whether auto-refresh turned itself off for safety.
    public var isSafetyStop: Bool {
        if case .disabledForSafety = self { return true }
        return false
    }

    /// Whether the user should be told something is wrong.
    public var needsAttention: Bool {
        switch self {
        case .off, .ok, .running: false
        case .notFound, .unsupportedVersion, .notLoggedIn, .failed, .disabledForSafety: true
        }
    }
}

/// When the next automatic run may start after one ended, and the updated failure count.
public struct CLIRetry: Equatable, Sendable {
    /// Seconds to wait, already clamped with ``RefreshPlanner/clampDelay(_:)``.
    public var delay: TimeInterval
    /// Failed runs in a row, including the one just made.
    public var consecutiveFailures: Int

    public init(delay: TimeInterval, consecutiveFailures: Int) {
        self.delay = delay
        self.consecutiveFailures = consecutiveFailures
    }
}

extension RefreshPlanner {
    /// The shortest time between two automatic runs of Claude Code.
    public static let minimumCLISpacing: TimeInterval = 120

    /// The shortest time between a run and one started with the Refresh button: the button's cooldown.
    public static let manualCLISpacing: TimeInterval = 60

    /// Whether an automatic run of Claude Code's `/usage` should start now.
    ///
    /// Only when the feature is enabled, the freshest snapshot (from any source) is at least `refreshInterval` old or
    /// there is none, the last run started at least ``minimumCLISpacing`` ago, and any back-off has elapsed
    /// (`now >= nextAllowedAt`). A snapshot dated in the future counts as fresh. A last run dated in the future (the
    /// clock was set back) does not hold runs back.
    public static func shouldRunCLIRefresh(
        enabled: Bool,
        freshest: UsageSnapshot?,
        now: Date,
        refreshInterval: TimeInterval,
        lastRunAt: Date?,
        nextAllowedAt: Date?
    ) -> Bool {
        guard enabled else { return false }
        if let lastRunAt {
            let sinceLastRun = now.timeIntervalSince(lastRunAt)
            if sinceLastRun >= 0, sinceLastRun < minimumCLISpacing { return false }
        }
        if let nextAllowedAt, now < nextAllowedAt { return false }
        guard let freshest else { return true }
        return now.timeIntervalSince(freshest.fetchedAt) >= refreshInterval
    }

    /// Whether the Refresh button may start a run now: at least ``manualCLISpacing`` after the last one. The age of
    /// the data and any back-off do not matter; the user asked.
    public static func manualCLIRefreshAllowed(lastRunAt: Date?, now: Date) -> Bool {
        guard let lastRunAt else { return true }
        let sinceLastRun = now.timeIntervalSince(lastRunAt)
        return sinceLastRun < 0 || sinceLastRun >= manualCLISpacing
    }

    /// How long to wait before the next automatic run after `outcome`.
    ///
    /// - A success resets the failure count; the next run is at least ``minimumCLISpacing`` away (in practice the age
    ///   check defers it to the next interval).
    /// - Any failure, including "not logged in", counts and backs off exponentially, exactly like Live mode
    ///   (``PollingPolicy``).
    /// - After a detected model request the feature is off; the longest delay is returned for completeness.
    ///
    /// - Parameter random: A uniform sample in `0...1`, as in ``PollingPolicy``.
    public static func cliRetry(
        after outcome: CLIRefreshOutcome,
        consecutiveFailures: Int,
        policy: PollingPolicy,
        random: Double
    ) -> CLIRetry {
        let failures = max(0, consecutiveFailures)
        switch outcome {
        case .success:
            return CLIRetry(delay: clampDelay(minimumCLISpacing), consecutiveFailures: 0)
        case .modelCallDetected:
            return CLIRetry(delay: delayRange.upperBound, consecutiveFailures: failures + 1)
        case .notLoggedIn, .failed:
            let delay = policy.nextDelay(after: .failure, consecutiveFailures: failures + 1, random: random)
            return CLIRetry(delay: clampDelay(delay), consecutiveFailures: failures + 1)
        }
    }

    /// Seconds until an automatic run could next be due: when the freshest snapshot reaches `refreshInterval` of age,
    /// ``minimumCLISpacing`` after the last run, or when the back-off ends, whichever is latest. Clamped with
    /// ``clampDelay(_:)``.
    public static func nextCLICheckDelay(
        freshest: UsageSnapshot?,
        now: Date,
        refreshInterval: TimeInterval,
        lastRunAt: Date?,
        nextAllowedAt: Date?
    ) -> TimeInterval {
        var wait: TimeInterval = 0
        if let freshest {
            wait = max(wait, freshest.fetchedAt.addingTimeInterval(refreshInterval).timeIntervalSince(now))
        }
        if let lastRunAt, lastRunAt <= now {
            wait = max(wait, lastRunAt.addingTimeInterval(minimumCLISpacing).timeIntervalSince(now))
        }
        if let nextAllowedAt {
            wait = max(wait, nextAllowedAt.timeIntervalSince(now))
        }
        return clampDelay(wait)
    }

    /// The status to show after a run that started at `ranAt`.
    ///
    /// - Parameter binary: The tool the run used or found, from its report; it names a Claude Code that is too old.
    public static func cliStatus(
        after outcome: CLIRefreshOutcome,
        ranAt: Date,
        binary: CLIBinaryState? = nil
    ) -> CLIRefreshStatus {
        switch outcome {
        case .success:
            return .ok(lastRun: ranAt)
        case .modelCallDetected:
            return .disabledForSafety(.modelCall)
        case .notLoggedIn:
            return .notLoggedIn
        case .failed(.notFound), .failed(.notClaudeCode):
            return .notFound
        case .failed(.unsupportedVersion):
            var version: String?
            if case .unsupported(let found) = binary?.versionCheck {
                version = found
            }
            return .unsupportedVersion(path: binary?.location.executable?.path.path, version: version)
        case .failed(let reason):
            return .failed(reason)
        }
    }

    /// Whether a run must be followed by a forced read of Claude Code's cache before it can be resolved: only a
    /// success that was not abandoned.
    public static func cliRunNeedsCacheRead(outcome: CLIRefreshOutcome, abandoned: Bool) -> Bool {
        outcome == .success && !abandoned
    }

    /// What to do with a finished run.
    ///
    /// - A detected model request is always applied, even when the run was abandoned (the Mac went to sleep, the
    ///   feature was turned off, the settings changed): the process finished and spent usage, so the feature must turn
    ///   itself off.
    /// - Anything else from an abandoned run is dropped.
    /// - A success counts only when the cache read afterwards shows a fresh entry (see
    ///   ``cliRunRefreshedCache(cachedFetchedAt:runStartedAt:)``). An entry that did not get newer is
    ///   ``CLIRefreshFailure/cacheNotUpdated``; a cache that could not be read at all (malformed, unreadable, too large,
    ///   another account's) or no read result is ``CLIRefreshFailure/cacheUnreadable``. A config directory changed
    ///   during the read abandons the run.
    public static func resolveCLIRun(
        outcome: CLIRefreshOutcome,
        abandoned: Bool,
        cacheRead: CLICacheReadResult?,
        runStartedAt: Date
    ) -> CLIRunResolution {
        if outcome == .modelCallDetected {
            return .apply(.modelCallDetected)
        }
        guard !abandoned else { return .abandon }
        guard outcome == .success else { return .apply(outcome) }
        switch cacheRead {
        case .read(let fetchedAt):
            return cliRunRefreshedCache(cachedFetchedAt: fetchedAt, runStartedAt: runStartedAt)
                ? .apply(.success) : .apply(.failed(.cacheNotUpdated))
        case .failed, nil:
            return .apply(.failed(.cacheUnreadable))
        case .configDirectoryChanged:
            return .abandon
        }
    }

    /// Whether to ask Claude Code if it is signed in before applying `outcome`: only after a run whose cache did not
    /// get newer, because a signed-out Claude Code (verified with 2.1.308) answers `/usage` like a success.
    public static func cliRunNeedsLoginCheck(_ outcome: CLIRefreshOutcome) -> Bool {
        outcome == .failed(.cacheNotUpdated)
    }

    /// `outcome` after the login check: a cache that did not get newer because Claude Code is signed out is
    /// ``CLIRefreshOutcome/notLoggedIn``, which tells the user what to do. Anything else, or no answer, stays as it is.
    public static func cliOutcome(_ outcome: CLIRefreshOutcome, loggedIn: Bool?) -> CLIRefreshOutcome {
        cliRunNeedsLoginCheck(outcome) && loggedIn == false ? .notLoggedIn : outcome
    }

    /// How many runs in a row may exit normally with output that cannot be checked before auto-refresh turns itself
    /// off (``CLISafetyStop/unverifiableOutput``).
    public static let unverifiedRunLimit = 3

    /// The safety switch-off after `outcome`.
    ///
    /// - A detected model request stops at once.
    /// - A run that exited with status 0 but whose output could not be verified (``CLIRefreshFailure/unparsable``,
    ///   ``CLIRefreshFailure/unexpectedOutput``) counts; the ``unverifiedRunLimit``-th in a row stops.
    /// - An answer whose shape was checked (success, not logged in, a reported error, a success whose cache did not
    ///   help) resets the count.
    /// - Runs that did not exit normally (timeouts, failed exits, launch failures, too much output) and runs that never
    ///   happened (nothing found, too old) neither count nor reset it.
    public static func cliSafety(after outcome: CLIRefreshOutcome, unverifiedRuns: Int) -> CLISafetyCheck {
        let count = max(0, unverifiedRuns)
        switch outcome {
        case .modelCallDetected:
            return CLISafetyCheck(unverifiedRuns: 0, stop: .modelCall)
        case .failed(.unparsable), .failed(.unexpectedOutput):
            let next = count + 1
            return next >= unverifiedRunLimit
                ? CLISafetyCheck(unverifiedRuns: 0, stop: .unverifiableOutput)
                : CLISafetyCheck(unverifiedRuns: next, stop: nil)
        case .success, .notLoggedIn, .failed(.reportedError), .failed(.cacheNotUpdated), .failed(.cacheUnreadable):
            return CLISafetyCheck(unverifiedRuns: 0, stop: nil)
        case .failed:
            return CLISafetyCheck(unverifiedRuns: count, stop: nil)
        }
    }

    /// Whether Claude Code's cache is fresh after a run that reported success: its entry was fetched no more than
    /// ``minimumCLISpacing`` before the run started (Claude Code may reuse a reading that young), or later. If not, the
    /// run did nothing useful, for example because the account has no subscription usage to report.
    public static func cliRunRefreshedCache(cachedFetchedAt: Date?, runStartedAt: Date) -> Bool {
        guard let cachedFetchedAt else { return false }
        return runStartedAt.timeIntervalSince(cachedFetchedAt) <= minimumCLISpacing
    }
}
