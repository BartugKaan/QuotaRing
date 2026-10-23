import Foundation
import Security
import Testing

@testable import QuotaRingCore

@Suite struct RefreshPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    private func snapshot(age: TimeInterval, source: SnapshotSource = .claudeCodeCache) -> UsageSnapshot {
        UsageSnapshot(
            report: UsageReport(limits: [UsageLimit(kind: .session, percentUsed: 40)]),
            fetchedAt: now.addingTimeInterval(-age),
            source: source
        )
    }

    // MARK: - shouldFetchLive

    @Test func liveDisabledNeverFetches() {
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: false, freshest: nil, now: now, refreshInterval: 300, nextAllowedLiveAt: nil))
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: false, freshest: snapshot(age: 10_000), now: now, refreshInterval: 300,
                nextAllowedLiveAt: nil))
    }

    @Test func fetchesWithoutAnySnapshot() {
        #expect(
            RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: nil, now: now, refreshInterval: 300, nextAllowedLiveAt: nil))
    }

    @Test func fetchesOnlyOnceSnapshotIsAsOldAsInterval() {
        func decide(age: TimeInterval) -> Bool {
            RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: snapshot(age: age), now: now, refreshInterval: 300,
                nextAllowedLiveAt: nil)
        }
        #expect(!decide(age: 0))
        #expect(!decide(age: 299))
        #expect(decide(age: 300))
        #expect(decide(age: 301))
        // A cached snapshot from Claude Code counts exactly like a live one: no request while it is fresh.
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: snapshot(age: 60, source: .live), now: now, refreshInterval: 300,
                nextAllowedLiveAt: nil))
    }

    @Test func snapshotFromTheFutureCountsAsFresh() {
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: snapshot(age: -600), now: now, refreshInterval: 300,
                nextAllowedLiveAt: nil))
    }

    @Test func respectsNextAllowedTime() {
        let stale = snapshot(age: 10_000)
        func decide(nextAllowedIn offset: TimeInterval) -> Bool {
            RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: stale, now: now, refreshInterval: 300,
                nextAllowedLiveAt: now.addingTimeInterval(offset))
        }
        #expect(!decide(nextAllowedIn: 1))
        #expect(!decide(nextAllowedIn: 1_800))
        #expect(decide(nextAllowedIn: 0))
        #expect(decide(nextAllowedIn: -1))

        // Back-off also applies when there is no snapshot at all.
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: nil, now: now, refreshInterval: 300,
                nextAllowedLiveAt: now.addingTimeInterval(60)))
    }

    @Test func suspensionStopsAutomaticRequests() {
        // Even with an old snapshot and no back-off, a suspended Live mode asks nothing by itself.
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: snapshot(age: 10_000), now: now, refreshInterval: 300,
                nextAllowedLiveAt: nil, isSuspended: true))
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: nil, now: now, refreshInterval: 300, nextAllowedLiveAt: nil,
                isSuspended: true))
        #expect(
            RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: nil, now: now, refreshInterval: 300, nextAllowedLiveAt: nil,
                isSuspended: false))
    }

    // MARK: - Keychain refusal

    @Test func keychainRefusalIsItsOwnStatus() {
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            #expect(
                RefreshPlanner.liveStatus(
                    for: .skippedNoCredential(.keychain(status)), now: now, retryAfterFallback: 600)
                    == .keychainDenied)
        }
    }

    @Test func onlyKeychainRefusalSuspendsAutomaticRequests() {
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            #expect(RefreshPlanner.suspendsAutomaticRequests(after: .skippedNoCredential(.keychain(status))))
        }
        let others: [LiveFetchResult] = [
            .snapshot(snapshot(age: 0, source: .live)),
            .skippedExpired,
            .skippedNoCredential(.notFound),
            .skippedNoCredential(.insecureFile),
            .skippedNoCredential(.keychain(errSecNoSuchKeychain)),
            .failed(.unauthorized),
            .failed(.network),
            .failed(.rateLimited(retryAfter: 60)),
        ]
        for result in others {
            #expect(!RefreshPlanner.suspendsAutomaticRequests(after: result), "\(result)")
        }
    }

    @Test func keychainRefusalCountsNoFailure() {
        let retry = RefreshPlanner.retry(
            after: .skippedNoCredential(.keychain(errSecUserCanceled)), consecutiveFailures: 2, policy: policy,
            random: 0.5)
        #expect(retry == LiveRetry(delay: 300, consecutiveFailures: 2))
    }

    // MARK: - liveStatus

    @Test func mapsEveryFetchResult() {
        func status(_ result: LiveFetchResult) -> LiveStatus {
            RefreshPlanner.liveStatus(for: result, now: now, retryAfterFallback: 600)
        }
        #expect(status(.snapshot(snapshot(age: 0, source: .live))) == .ok)
        #expect(status(.skippedExpired) == .expired)
        #expect(status(.skippedNoCredential(.notFound)) == .noCredential)
        #expect(status(.skippedNoCredential(.missingClaudeAiOauth)) == .noCredential)
        #expect(status(.skippedNoCredential(.keychain(errSecNoSuchKeychain))) == .noCredential)
        #expect(status(.failed(.unauthorized)) == .expired)
        #expect(status(.failed(.server(status: 500))) == .error)
        #expect(status(.failed(.server(status: 302))) == .error)
        #expect(status(.failed(.network)) == .error)
        #expect(status(.failed(.decoding)) == .error)
    }

    @Test func rateLimitedUsesRetryAfterOrFallback() {
        #expect(
            RefreshPlanner.liveStatus(
                for: .failed(.rateLimited(retryAfter: 120)), now: now, retryAfterFallback: 600)
                == .rateLimited(until: now.addingTimeInterval(120)))
        #expect(
            RefreshPlanner.liveStatus(
                for: .failed(.rateLimited(retryAfter: nil)), now: now, retryAfterFallback: 600)
                == .rateLimited(until: now.addingTimeInterval(600)))
    }

    @Test func rateLimitedUntilIsClamped() {
        // A hostile Retry-After must not announce (or cause) a pause of days.
        #expect(
            RefreshPlanner.liveStatus(
                for: .failed(.rateLimited(retryAfter: 9_999_999)), now: now, retryAfterFallback: 600)
                == .rateLimited(until: now.addingTimeInterval(21_600)))
        #expect(
            RefreshPlanner.liveStatus(
                for: .failed(.rateLimited(retryAfter: 0)), now: now, retryAfterFallback: 600)
                == .rateLimited(until: now.addingTimeInterval(1)))
    }

    // MARK: - clampDelay

    @Test func clampDelayBounds() {
        #expect(RefreshPlanner.clampDelay(30) == 30)
        #expect(RefreshPlanner.clampDelay(1) == 1)
        #expect(RefreshPlanner.clampDelay(21_600) == 21_600)
        #expect(RefreshPlanner.clampDelay(0) == 1)
        #expect(RefreshPlanner.clampDelay(0.25) == 1)
        #expect(RefreshPlanner.clampDelay(-5) == 1)
        #expect(RefreshPlanner.clampDelay(21_601) == 21_600)
        #expect(RefreshPlanner.clampDelay(1e12) == 21_600)
        #expect(RefreshPlanner.clampDelay(.infinity) == 21_600)
        #expect(RefreshPlanner.clampDelay(-.infinity) == 1)
        // A NaN would otherwise slip through min/max; waiting long is the safe direction.
        #expect(RefreshPlanner.clampDelay(.nan) == 21_600)
    }

    // MARK: - retry

    private let policy = PollingPolicy(baseInterval: 300, maxBackoff: 1800, jitterFraction: 0.1)

    @Test func successResetsFailuresAndKeepsMinimumSpacing() {
        let retry = RefreshPlanner.retry(
            after: .snapshot(snapshot(age: 0, source: .live)), consecutiveFailures: 3, policy: policy, random: 0.5)
        #expect(retry == LiveRetry(delay: 60, consecutiveFailures: 0))
        #expect(RefreshPlanner.minimumLiveSpacing == 60)
    }

    @Test func skippedFetchWaitsOneJitteredInterval() {
        let expired = RefreshPlanner.retry(
            after: .skippedExpired, consecutiveFailures: 0, policy: policy, random: 0.5)
        #expect(expired == LiveRetry(delay: 300, consecutiveFailures: 0))

        let missing = RefreshPlanner.retry(
            after: .skippedNoCredential(.notFound), consecutiveFailures: 2, policy: policy, random: 0)
        // No request was made, so the failure count is left alone.
        #expect(missing == LiveRetry(delay: 270, consecutiveFailures: 2))
    }

    @Test func failuresBackOffExponentiallyWithCap() {
        var failures = 0
        var delays: [TimeInterval] = []
        for result: LiveFetchResult in [.failed(.network), .failed(.server(status: 503)), .failed(.unauthorized)] {
            let retry = RefreshPlanner.retry(after: result, consecutiveFailures: failures, policy: policy, random: 0.5)
            failures = retry.consecutiveFailures
            delays.append(retry.delay)
        }
        #expect(delays == [600, 1200, 1800])
        #expect(failures == 3)

        let decoding = RefreshPlanner.retry(
            after: .failed(.decoding), consecutiveFailures: 10, policy: policy, random: 0.5)
        #expect(decoding == LiveRetry(delay: 1800, consecutiveFailures: 11))
    }

    @Test func rateLimitHonorsRetryAfterWithinClamp() {
        let hinted = RefreshPlanner.retry(
            after: .failed(.rateLimited(retryAfter: 900)), consecutiveFailures: 0, policy: policy, random: 0.5)
        #expect(hinted == LiveRetry(delay: 900, consecutiveFailures: 1))

        // A short hint never polls sooner than the base interval.
        let short = RefreshPlanner.retry(
            after: .failed(.rateLimited(retryAfter: 5)), consecutiveFailures: 0, policy: policy, random: 0.5)
        #expect(short.delay == 300)

        let unhinted = RefreshPlanner.retry(
            after: .failed(.rateLimited(retryAfter: nil)), consecutiveFailures: 1, policy: policy, random: 0.5)
        #expect(unhinted == LiveRetry(delay: 1200, consecutiveFailures: 2))

        let hostile = RefreshPlanner.retry(
            after: .failed(.rateLimited(retryAfter: 9_999_999)), consecutiveFailures: 0, policy: policy,
            random: 0.5)
        #expect(hostile.delay == 21_600)
    }

    // MARK: - nextCheckDelay

    @Test func nextCheckWaitsUntilSnapshotAges() {
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: 100), now: now, refreshInterval: 300, nextAllowedLiveAt: nil) == 200)
        // Already old enough: check again almost immediately (never a busy loop).
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: 900), now: now, refreshInterval: 300, nextAllowedLiveAt: nil) == 1)
        #expect(
            RefreshPlanner.nextCheckDelay(freshest: nil, now: now, refreshInterval: 300, nextAllowedLiveAt: nil) == 1)
    }

    @Test func nextCheckWaitsForTheLaterOfAgeAndBackoff() {
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: 100), now: now, refreshInterval: 300,
                nextAllowedLiveAt: now.addingTimeInterval(1_200)) == 1_200)
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: 100), now: now, refreshInterval: 300,
                nextAllowedLiveAt: now.addingTimeInterval(50)) == 200)
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: -1_000_000), now: now, refreshInterval: 300, nextAllowedLiveAt: nil)
                == 21_600)
    }

    @Test func nextCheckWhileSuspendedIsTheLongestWait() {
        // The state a Keychain refusal leaves a few minutes later: an old snapshot and a back-off that has ended. Not
        // suspended, that is "check again at once" (the loop's one-second floor); suspended, nothing can become due.
        let stale = snapshot(age: 900)
        let backOffOver = now.addingTimeInterval(-60)
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: stale, now: now, refreshInterval: 300, nextAllowedLiveAt: backOffOver) == 1)
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: stale, now: now, refreshInterval: 300, nextAllowedLiveAt: backOffOver, isSuspended: true)
                == RefreshPlanner.delayRange.upperBound)
    }

    @Test func nextCheckWhileSuspendedIgnoresEverythingElse() {
        for freshest in [nil, snapshot(age: 0), snapshot(age: 900), snapshot(age: -1_000_000)] {
            for nextAllowed in [nil, now.addingTimeInterval(-60), now.addingTimeInterval(120)] {
                #expect(
                    RefreshPlanner.nextCheckDelay(
                        freshest: freshest, now: now, refreshInterval: 300, nextAllowedLiveAt: nextAllowed,
                        isSuspended: true) == 21_600)
            }
        }
    }

    @Test func nextCheckIsUnchangedWhenNotSuspended() {
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: 100), now: now, refreshInterval: 300, nextAllowedLiveAt: nil, isSuspended: false
            )
                == 200)
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: snapshot(age: 100), now: now, refreshInterval: 300,
                nextAllowedLiveAt: now.addingTimeInterval(1_200), isSuspended: false) == 1_200)
    }

    @Test func aSuspendedLoopNeverBecomesDueByItself() {
        // The loop wakes after the long wait and asks the planner again: still not due, still the long wait.
        let stale = snapshot(age: 900)
        let later = now.addingTimeInterval(RefreshPlanner.delayRange.upperBound)
        #expect(
            !RefreshPlanner.shouldFetchLive(
                liveEnabled: true, freshest: stale, now: later, refreshInterval: 300, nextAllowedLiveAt: nil,
                isSuspended: true))
        #expect(
            RefreshPlanner.nextCheckDelay(
                freshest: stale, now: later, refreshInterval: 300, nextAllowedLiveAt: nil, isSuspended: true)
                == RefreshPlanner.delayRange.upperBound)
    }
}
