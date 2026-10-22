import Foundation

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
    /// Claude Code answered `/usage` with a model request, so the feature turned itself off.
    case disabledForSafety

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
            return .disabledForSafety
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

    /// Whether Claude Code's cache is fresh after a run that reported success: its entry was fetched no more than
    /// ``minimumCLISpacing`` before the run started (Claude Code may reuse a reading that young), or later. If not, the
    /// run did nothing useful, for example because the account has no subscription usage to report.
    public static func cliRunRefreshedCache(cachedFetchedAt: Date?, runStartedAt: Date) -> Bool {
        guard let cachedFetchedAt else { return false }
        return runStartedAt.timeIntervalSince(cachedFetchedAt) <= minimumCLISpacing
    }
}
