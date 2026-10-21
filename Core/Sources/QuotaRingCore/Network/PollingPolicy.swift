import Foundation

/// What happened on the last poll of the usage endpoint.
public enum PollOutcome: Sendable, Equatable {
    case success
    /// The endpoint answered 429; `retryAfter` is the server's hint in seconds, if it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    case failure
}

/// How long to wait before the next poll: the base interval with jitter after a success, exponential back-off after a
/// failure, and the server's own hint after a rate limit.
public struct PollingPolicy: Sendable {
    public var baseInterval: TimeInterval
    public var maxBackoff: TimeInterval
    /// Fraction of `baseInterval` by which a successful poll's delay may deviate either way, for example `0.1` for ±10 %.
    public var jitterFraction: Double

    public init(baseInterval: TimeInterval = 300, maxBackoff: TimeInterval = 1800, jitterFraction: Double = 0.1) {
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
        self.jitterFraction = jitterFraction
    }

    /// - Parameters:
    ///   - outcome: Result of the poll that just finished.
    ///   - consecutiveFailures: Failed polls in a row, including this one. Values below 1 count as 1 when it matters.
    ///   - random: A uniform sample in `0...1`; injected so the result is deterministic in tests. Out-of-range values
    ///     are clamped and a NaN counts as `0.5` (no jitter).
    /// - Returns: Seconds to wait before polling again.
    public func nextDelay(after outcome: PollOutcome, consecutiveFailures: Int, random: Double) -> TimeInterval {
        switch outcome {
        case .success:
            let sample = random.isNaN ? 0.5 : min(1, max(0, random))
            return baseInterval * (1 + jitterFraction * (2 * sample - 1))
        case .failure, .rateLimited(retryAfter: nil):
            return backoff(consecutiveFailures: consecutiveFailures)
        case .rateLimited(retryAfter: let hint?):
            // Never poll sooner than the base interval, and honor a longer wait the server asked for.
            return max(hint, min(baseInterval, maxBackoff))
        }
    }

    private func backoff(consecutiveFailures: Int) -> TimeInterval {
        // The exponent is capped so the multiplication cannot overflow; the result is bounded by `maxBackoff` anyway.
        let exponent = min(max(consecutiveFailures, 1), 30)
        return min(maxBackoff, baseInterval * pow(2, Double(exponent)))
    }
}
