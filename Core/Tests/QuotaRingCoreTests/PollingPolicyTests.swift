import Testing

@testable import QuotaRingCore

@Suite struct PollingPolicyTests {
    private let policy = PollingPolicy()

    private func approximately(_ actual: Double, _ expected: Double) -> Bool {
        abs(actual - expected) < 1e-9
    }

    @Test func defaults() {
        #expect(policy.baseInterval == 300)
        #expect(policy.maxBackoff == 1800)
        #expect(policy.jitterFraction == 0.1)
    }

    @Test func successJitterBounds() {
        let low = policy.nextDelay(after: .success, consecutiveFailures: 0, random: 0)
        #expect(approximately(low, 270))

        let middle = policy.nextDelay(after: .success, consecutiveFailures: 0, random: 0.5)
        #expect(approximately(middle, 300))

        let high = policy.nextDelay(after: .success, consecutiveFailures: 0, random: 0.9999999999)
        #expect(high < 330)
        #expect(high > 329.99)
    }

    @Test func successJitterIgnoresOutOfRangeRandom() {
        #expect(approximately(policy.nextDelay(after: .success, consecutiveFailures: 0, random: -3), 270))
        #expect(approximately(policy.nextDelay(after: .success, consecutiveFailures: 0, random: 7), 330))
        #expect(approximately(policy.nextDelay(after: .success, consecutiveFailures: 0, random: .nan), 300))
    }

    @Test func successUsesConfiguredBase() {
        let custom = PollingPolicy(baseInterval: 600, maxBackoff: 1800, jitterFraction: 0.1)
        #expect(approximately(custom.nextDelay(after: .success, consecutiveFailures: 0, random: 0.5), 600))
    }

    @Test func backoffDoubles() {
        func delay(_ failures: Int) -> Double {
            policy.nextDelay(after: .failure, consecutiveFailures: failures, random: 0.5)
        }
        #expect(delay(1) == 600)
        #expect(delay(2) == 1200)
        #expect(delay(3) == 1800)
        #expect(delay(5) == 1800)
        #expect(delay(1000) == 1800)
    }

    @Test func backoffTreatsZeroOrNegativeFailuresAsFirst() {
        #expect(policy.nextDelay(after: .failure, consecutiveFailures: 0, random: 0.5) == 600)
        #expect(policy.nextDelay(after: .failure, consecutiveFailures: -4, random: 0.5) == 600)
    }

    @Test func rateLimitedWithoutHintBacksOffLikeFailure() {
        #expect(policy.nextDelay(after: .rateLimited(retryAfter: nil), consecutiveFailures: 1, random: 0.5) == 600)
        #expect(policy.nextDelay(after: .rateLimited(retryAfter: nil), consecutiveFailures: 2, random: 0.5) == 1200)
        #expect(policy.nextDelay(after: .rateLimited(retryAfter: nil), consecutiveFailures: 9, random: 0.5) == 1800)
    }

    @Test func retryAfterRespected() {
        let delay = policy.nextDelay(after: .rateLimited(retryAfter: 900), consecutiveFailures: 1, random: 0.5)
        #expect(delay >= 900)
        #expect(delay == 900)
    }

    @Test func retryAfterNeverBelowBase() {
        let delay = policy.nextDelay(after: .rateLimited(retryAfter: 10), consecutiveFailures: 1, random: 0.5)
        #expect(delay >= 300)
        #expect(delay == 300)
        #expect(policy.nextDelay(after: .rateLimited(retryAfter: 0), consecutiveFailures: 1, random: 0.5) == 300)
    }

    @Test func retryAfterAboveMaxBackoffIsHonored() {
        let delay = policy.nextDelay(after: .rateLimited(retryAfter: 7200), consecutiveFailures: 1, random: 0.5)
        #expect(delay == 7200)
    }

    @Test func retryAfterBetweenBaseAndMaxIsNotInflated() {
        let delay = policy.nextDelay(after: .rateLimited(retryAfter: 1500), consecutiveFailures: 4, random: 0.5)
        #expect(delay == 1500)
    }
}
