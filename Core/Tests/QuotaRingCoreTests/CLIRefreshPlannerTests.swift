import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct CLIRefreshPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    private func snapshot(age: TimeInterval) -> UsageSnapshot {
        UsageSnapshot(
            report: UsageReport(limits: [UsageLimit(kind: .session, percentUsed: 40)]),
            fetchedAt: now.addingTimeInterval(-age),
            source: .claudeCodeCache
        )
    }

    private func decide(
        enabled: Bool = true,
        age: TimeInterval? = 10_000,
        lastRunAgo: TimeInterval? = nil,
        nextAllowedIn: TimeInterval? = nil
    ) -> Bool {
        RefreshPlanner.shouldRunCLIRefresh(
            enabled: enabled,
            freshest: age.map(snapshot(age:)),
            now: now,
            refreshInterval: 300,
            lastRunAt: lastRunAgo.map { now.addingTimeInterval(-$0) },
            nextAllowedAt: nextAllowedIn.map { now.addingTimeInterval($0) }
        )
    }

    // MARK: - shouldRunCLIRefresh

    @Test func disabledNeverRuns() {
        #expect(!decide(enabled: false))
        #expect(!decide(enabled: false, age: nil))
    }

    @Test func runsWithoutAnySnapshot() {
        #expect(decide(age: nil))
    }

    @Test func runsOnlyOnceTheSnapshotIsAsOldAsTheInterval() {
        #expect(!decide(age: 0))
        #expect(!decide(age: 299))
        #expect(decide(age: 300))
        #expect(decide(age: 301))
    }

    @Test func snapshotFromTheFutureCountsAsFresh() {
        #expect(!decide(age: -600))
    }

    @Test func neverMoreOftenThanEveryTwoMinutes() {
        #expect(RefreshPlanner.minimumCLISpacing == 120)
        #expect(!decide(lastRunAgo: 0))
        #expect(!decide(lastRunAgo: 119))
        #expect(decide(lastRunAgo: 120))
        #expect(decide(lastRunAgo: 3_600))
        // Also without any snapshot, and even with a short refresh interval.
        #expect(!decide(age: nil, lastRunAgo: 60))
        #expect(
            !RefreshPlanner.shouldRunCLIRefresh(
                enabled: true, freshest: snapshot(age: 100), now: now, refreshInterval: 30,
                lastRunAt: now.addingTimeInterval(-90), nextAllowedAt: nil))
    }

    @Test func aLastRunInTheFutureDoesNotHoldRunsBack() {
        // The clock was set back: waiting for it to catch up could take days.
        #expect(decide(lastRunAgo: -3_600))
    }

    @Test func respectsTheBackoff() {
        #expect(!decide(nextAllowedIn: 1))
        #expect(!decide(nextAllowedIn: 1_800))
        #expect(decide(nextAllowedIn: 0))
        #expect(decide(nextAllowedIn: -1))
        #expect(!decide(age: nil, nextAllowedIn: 60))
    }

    // MARK: - Manual

    @Test func refreshButtonWaitsAMinuteAfterTheLastRun() {
        func manual(lastRunAgo: TimeInterval?) -> Bool {
            RefreshPlanner.manualCLIRefreshAllowed(lastRunAt: lastRunAgo.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(manual(lastRunAgo: nil))
        #expect(!manual(lastRunAgo: 0))
        #expect(!manual(lastRunAgo: 59))
        #expect(manual(lastRunAgo: 60))
        #expect(manual(lastRunAgo: -600))
    }

    // MARK: - Retry

    private let policy = PollingPolicy(baseInterval: 300)

    @Test func successResetsFailures() {
        #expect(
            RefreshPlanner.cliRetry(after: .success, consecutiveFailures: 4, policy: policy, random: 0.5)
                == CLIRetry(delay: 120, consecutiveFailures: 0))
    }

    @Test func failuresBackOffLikeLiveMode() {
        var failures = 0
        var delays: [TimeInterval] = []
        for _ in 0..<5 {
            let retry = RefreshPlanner.cliRetry(
                after: .failed(.timedOut), consecutiveFailures: failures, policy: policy, random: 0.5)
            failures = retry.consecutiveFailures
            delays.append(retry.delay)
        }
        #expect(delays == [600, 1_200, 1_800, 1_800, 1_800])
        #expect(failures == 5)
    }

    @Test func notLoggedInAndNotFoundBackOffToo() {
        for outcome: CLIRefreshOutcome in [.notLoggedIn, .failed(.notFound), .failed(.cacheNotUpdated)] {
            #expect(
                RefreshPlanner.cliRetry(after: outcome, consecutiveFailures: 1, policy: policy, random: 0)
                    == CLIRetry(delay: 1_200, consecutiveFailures: 2))
        }
    }

    @Test func modelCallWaitsTheLongestPossible() {
        #expect(
            RefreshPlanner.cliRetry(after: .modelCallDetected, consecutiveFailures: 0, policy: policy, random: 0.5)
                == CLIRetry(delay: RefreshPlanner.delayRange.upperBound, consecutiveFailures: 1))
    }

    // MARK: - Next check

    @Test func nextCheckWaitsForTheLatestCondition() {
        func delay(age: TimeInterval?, lastRunAgo: TimeInterval?, nextAllowedIn: TimeInterval?) -> TimeInterval {
            RefreshPlanner.nextCLICheckDelay(
                freshest: age.map(snapshot(age:)), now: now, refreshInterval: 300,
                lastRunAt: lastRunAgo.map { now.addingTimeInterval(-$0) },
                nextAllowedAt: nextAllowedIn.map { now.addingTimeInterval($0) })
        }
        #expect(delay(age: 100, lastRunAgo: nil, nextAllowedIn: nil) == 200)
        #expect(delay(age: 10_000, lastRunAgo: 20, nextAllowedIn: nil) == 100)
        #expect(delay(age: 10_000, lastRunAgo: 20, nextAllowedIn: 600) == 600)
        #expect(delay(age: nil, lastRunAgo: nil, nextAllowedIn: nil) == 1)
        // A last run in the future is ignored, as in `shouldRunCLIRefresh`.
        #expect(delay(age: nil, lastRunAgo: -86_400, nextAllowedIn: nil) == 1)
        #expect(delay(age: nil, lastRunAgo: nil, nextAllowedIn: 1_000_000) == RefreshPlanner.delayRange.upperBound)
    }

    // MARK: - Status

    @Test func statusAfterEachOutcome() {
        #expect(RefreshPlanner.cliStatus(after: .success, ranAt: now) == .ok(lastRun: now))
        #expect(RefreshPlanner.cliStatus(after: .modelCallDetected, ranAt: now) == .disabledForSafety)
        #expect(RefreshPlanner.cliStatus(after: .notLoggedIn, ranAt: now) == .notLoggedIn)
        #expect(RefreshPlanner.cliStatus(after: .failed(.notFound), ranAt: now) == .notFound)
        #expect(RefreshPlanner.cliStatus(after: .failed(.notClaudeCode), ranAt: now) == .notFound)
        #expect(RefreshPlanner.cliStatus(after: .failed(.timedOut), ranAt: now) == .failed(.timedOut))
        #expect(RefreshPlanner.cliStatus(after: .failed(.cacheNotUpdated), ranAt: now) == .failed(.cacheNotUpdated))
    }

    @Test func anOldClaudeCodeIsReportedWithItsPathAndVersion() throws {
        let tool = URL(fileURLWithPath: "/usr/local/bin/claude")
        let executable = CLIExecutable(
            path: tool, executable: URL(fileURLWithPath: "/usr/local/lib/node_modules/claude/cli.js"),
            identity: CLIFileIdentity(
                path: "/usr/local/lib/node_modules/claude/cli.js", device: 1, inode: 2, size: 3,
                modifiedNanoseconds: 4))
        let binary = CLIBinaryState(
            location: CLILocation(executable: executable, customPathProblem: nil),
            versionCheck: .unsupported(version: "1.0.113"))
        #expect(
            RefreshPlanner.cliStatus(after: .failed(.unsupportedVersion), ranAt: now, binary: binary)
                == .unsupportedVersion(path: "/usr/local/bin/claude", version: "1.0.113"))
        // Without the tool's details there is still something true to say.
        #expect(
            RefreshPlanner.cliStatus(after: .failed(.unsupportedVersion), ranAt: now)
                == .unsupportedVersion(path: nil, version: nil))
        #expect(CLIRefreshStatus.unsupportedVersion(path: nil, version: nil).needsAttention)
        // Other outcomes do not depend on the tool.
        #expect(RefreshPlanner.cliStatus(after: .success, ranAt: now, binary: binary) == .ok(lastRun: now))
    }

    @Test func onlyProblemsNeedAttention() {
        #expect(!CLIRefreshStatus.off.needsAttention)
        #expect(!CLIRefreshStatus.ok(lastRun: nil).needsAttention)
        #expect(!CLIRefreshStatus.running.needsAttention)
        #expect(CLIRefreshStatus.notFound.needsAttention)
        #expect(CLIRefreshStatus.notLoggedIn.needsAttention)
        #expect(CLIRefreshStatus.failed(.exitStatus).needsAttention)
        #expect(CLIRefreshStatus.disabledForSafety.needsAttention)
    }

    // MARK: - Did the run help?

    @Test func aRunRefreshedTheCacheWhenItsEntryIsNewOrYoung() {
        let started = now
        #expect(
            RefreshPlanner.cliRunRefreshedCache(cachedFetchedAt: started.addingTimeInterval(2), runStartedAt: started))
        #expect(
            RefreshPlanner.cliRunRefreshedCache(
                cachedFetchedAt: started.addingTimeInterval(-100), runStartedAt: started))
        #expect(
            RefreshPlanner.cliRunRefreshedCache(
                cachedFetchedAt: started.addingTimeInterval(-120), runStartedAt: started))
        #expect(
            !RefreshPlanner.cliRunRefreshedCache(
                cachedFetchedAt: started.addingTimeInterval(-121), runStartedAt: started))
        #expect(!RefreshPlanner.cliRunRefreshedCache(cachedFetchedAt: nil, runStartedAt: started))
    }
}
