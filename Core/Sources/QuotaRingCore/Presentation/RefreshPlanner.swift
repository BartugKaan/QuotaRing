import Foundation

/// What the UI shows about Live mode.
public enum LiveStatus: Equatable, Sendable {
    /// Live mode is off (the default), or the app runs in demo mode.
    case off
    /// Live mode is on and nothing is wrong: the last request succeeded, or none was needed yet.
    case ok
    /// Claude Code's login has expired (or the endpoint answered 401/403); requests are paused until it is renewed.
    case expired
    /// No usable Claude Code credential was found.
    case noCredential
    /// The endpoint answered 429; the next request waits until `until`.
    case rateLimited(until: Date)
    /// The last request failed (network, server or decoding); the previous data stays on screen.
    case error
}

/// When the next automatic Live request may be made after a fetch, and the updated failure count.
public struct LiveRetry: Equatable, Sendable {
    /// Seconds to wait, already clamped with ``RefreshPlanner/clampDelay(_:)``.
    public var delay: TimeInterval
    /// Failed requests in a row, including the one just made.
    public var consecutiveFailures: Int

    public init(delay: TimeInterval, consecutiveFailures: Int) {
        self.delay = delay
        self.consecutiveFailures = consecutiveFailures
    }
}

/// The pure decisions behind the app's refresh loops, kept here so they are unit-tested: whether to ask the Live
/// endpoint now, how long to wait afterwards, and what to tell the user about it.
public enum RefreshPlanner {
    /// The shortest time between two Live requests, also the cooldown of a manual refresh.
    public static let minimumLiveSpacing: TimeInterval = 60

    /// Bounds of every scheduled wait: at least 1 s (never a busy loop) and at most 6 h, so a hostile or corrupted
    /// `Retry-After` cannot park Live mode for days.
    public static let delayRange: ClosedRange<TimeInterval> = 1...21_600

    /// Whether an automatic Live request should go out now.
    ///
    /// Only when Live mode is enabled, any back-off has elapsed (`now >= nextAllowedLiveAt`), and the freshest
    /// snapshot, from whichever source, is at least `refreshInterval` old. With no snapshot at all, the age check
    /// passes. A snapshot dated in the future counts as fresh.
    public static func shouldFetchLive(
        liveEnabled: Bool,
        freshest: UsageSnapshot?,
        now: Date,
        refreshInterval: TimeInterval,
        nextAllowedLiveAt: Date?
    ) -> Bool {
        guard liveEnabled else { return false }
        if let nextAllowedLiveAt, now < nextAllowedLiveAt { return false }
        guard let freshest else { return true }
        return now.timeIntervalSince(freshest.fetchedAt) >= refreshInterval
    }

    /// The Live status to show after a fetch.
    ///
    /// - Parameter retryAfterFallback: Seconds until the next attempt when a 429 came without a usable
    ///   `Retry-After`. The resulting wait is clamped like every other delay, so the announced time matches when the
    ///   app actually tries again.
    public static func liveStatus(
        for result: LiveFetchResult,
        now: Date,
        retryAfterFallback: TimeInterval
    ) -> LiveStatus {
        switch result {
        case .snapshot:
            return .ok
        case .skippedExpired, .failed(.unauthorized):
            return .expired
        case .skippedNoCredential:
            return .noCredential
        case .failed(.rateLimited(let retryAfter)):
            return .rateLimited(until: now.addingTimeInterval(clampDelay(retryAfter ?? retryAfterFallback)))
        case .failed(.server), .failed(.network), .failed(.decoding):
            return .error
        }
    }

    /// `delay` limited to ``delayRange``. A NaN becomes the upper bound: waiting long is the safe direction.
    public static func clampDelay(_ delay: TimeInterval) -> TimeInterval {
        guard !delay.isNaN else { return delayRange.upperBound }
        return min(delayRange.upperBound, max(delayRange.lowerBound, delay))
    }

    /// How long to wait before the next automatic Live request after `result`.
    ///
    /// - A snapshot resets the failure count; the next request is at least ``minimumLiveSpacing`` away (in practice
    ///   the age check in ``shouldFetchLive(liveEnabled:freshest:now:refreshInterval:nextAllowedLiveAt:)`` defers it
    ///   to the next interval).
    /// - A skipped fetch (expired or missing credential) made no request, so the failure count stays and the next
    ///   attempt is one jittered interval away.
    /// - Any failure, including 401/403, counts and backs off exponentially; a 429 also honors `Retry-After`.
    ///
    /// - Parameter random: A uniform sample in `0...1` for the jitter, as in ``PollingPolicy``.
    public static func retry(
        after result: LiveFetchResult,
        consecutiveFailures: Int,
        policy: PollingPolicy,
        random: Double
    ) -> LiveRetry {
        let failures = max(0, consecutiveFailures)
        switch result {
        case .snapshot:
            return LiveRetry(delay: clampDelay(minimumLiveSpacing), consecutiveFailures: 0)
        case .skippedExpired, .skippedNoCredential:
            let delay = policy.nextDelay(after: .success, consecutiveFailures: 0, random: random)
            return LiveRetry(delay: clampDelay(delay), consecutiveFailures: failures)
        case .failed(let error):
            let outcome: PollOutcome
            if case .rateLimited(let retryAfter) = error {
                outcome = .rateLimited(retryAfter: retryAfter)
            } else {
                outcome = .failure
            }
            let delay = policy.nextDelay(after: outcome, consecutiveFailures: failures + 1, random: random)
            return LiveRetry(delay: clampDelay(delay), consecutiveFailures: failures + 1)
        }
    }

    /// Seconds until an automatic Live request could next be due: when the freshest snapshot reaches
    /// `refreshInterval` of age, or when the back-off ends, whichever is later. Clamped with ``clampDelay(_:)``.
    public static func nextCheckDelay(
        freshest: UsageSnapshot?,
        now: Date,
        refreshInterval: TimeInterval,
        nextAllowedLiveAt: Date?
    ) -> TimeInterval {
        var wait: TimeInterval = 0
        if let freshest {
            wait = max(wait, freshest.fetchedAt.addingTimeInterval(refreshInterval).timeIntervalSince(now))
        }
        if let nextAllowedLiveAt {
            wait = max(wait, nextAllowedLiveAt.timeIntervalSince(now))
        }
        return clampDelay(wait)
    }
}
