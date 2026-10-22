import Foundation
import QuotaRingCore
import Testing
import UserNotifications

/// The notification texts. Only `NotificationService.request(for:session:now:)` is used: it builds the content
/// without a notification center, so no permission prompt appears and nothing is posted.
@MainActor
@Suite struct NotificationContentTests {
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    private func limit(used: Double, resetsIn: TimeInterval?) -> UsageLimit {
        UsageLimit(kind: .session, percentUsed: used, resetsAt: resetsIn.map { now.addingTimeInterval($0) })
    }

    @Test func aCrossedThresholdNamesThePercentWhatIsLeftAndTheReset() {
        let session = limit(used: 82, resetsIn: 4_920)  // 1 h 22 min

        let request = NotificationService.request(for: .crossed(80), session: session, now: now)

        #expect(request.identifier == "session-threshold-80")
        #expect(request.content.threadIdentifier == "session")
        // Delivered at once, not at some later time.
        #expect(request.trigger == nil)
        #expect(request.content.title.contains(QuotaFormat.percent(80)))
        #expect(request.content.body.contains(QuotaFormat.percent(18)))
        #expect(request.content.body.contains(QuotaFormat.countdown(to: now.addingTimeInterval(4_920), from: now)))
    }

    @Test func withoutAResetTimeOnlyWhatIsLeftIsShown() {
        let request = NotificationService.request(
            for: .crossed(95), session: limit(used: 96, resetsIn: nil), now: now)

        #expect(request.content.body.contains(QuotaFormat.percent(4)))
        #expect(!request.content.body.contains("·"))
    }

    @Test func withoutASessionThereIsATitleButNoBody() {
        let request = NotificationService.request(for: .crossed(80), session: nil, now: now)

        #expect(request.identifier == "session-threshold-80")
        #expect(!request.content.title.isEmpty)
        #expect(request.content.body.isEmpty)
    }

    @Test func theResetHasItsOwnIdentifierAndNoBody() {
        let request = NotificationService.request(for: .reset, session: limit(used: 0, resetsIn: 18_000), now: now)

        #expect(request.identifier == "session-reset")
        #expect(request.content.threadIdentifier == "session")
        #expect(!request.content.title.isEmpty)
        #expect(request.content.body.isEmpty)
    }

    @Test func eachThresholdHasItsOwnIdentifierSoOneDoesNotReplaceAnother() {
        let ids = [50, 80, 95, 100].map {
            NotificationService.request(for: .crossed($0), session: nil, now: now).identifier
        }
        #expect(Set(ids).count == ids.count)
        #expect(
            NotificationService.request(for: .reset, session: nil, now: now).identifier
                != NotificationService.request(for: .crossed(80), session: nil, now: now).identifier)
    }

    @Test func aSessionAlreadyOverShowsNothingLeft() {
        let request = NotificationService.request(
            for: .crossed(100), session: limit(used: 130, resetsIn: 600), now: now)

        #expect(request.content.body.contains(QuotaFormat.percent(0)))
    }
}

@Suite struct LogNameTests {
    private let later = Date(timeIntervalSince1970: 1_792_600_300)

    /// Log names go into the system log with `privacy: .public`, so they must be short fixed words: no path, no date,
    /// nothing the user typed.
    private func isSafe(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 40 && !name.contains("/") && !name.contains(" ") && !name.contains("@")
    }

    @Test func liveStatusNamesAreDistinctAndSafe() {
        let statuses: [LiveStatus] = [
            .off, .ok, .expired, .noCredential, .keychainDenied, .rateLimited(until: later), .error,
        ]
        let names = statuses.map(\.logName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy(isSafe))
        // The retry time is not part of the name.
        #expect(LiveStatus.rateLimited(until: later).logName == LiveStatus.rateLimited(until: .distantFuture).logName)
    }

    @Test func autoRefreshStatusNamesAreDistinctAndSafe() {
        var statuses: [CLIRefreshStatus] = [
            .off, .ok(lastRun: nil), .running, .notFound, .notLoggedIn,
            .unsupportedVersion(path: "/Users/someone/bin/claude", version: "1.0.0"),
        ]
        statuses += CLIRefreshFailure.allCases.map { .failed($0) }
        statuses += CLISafetyStop.allCases.map { .disabledForSafety($0) }
        let names = statuses.map(\.logName)

        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy(isSafe))
        // A path or a last-run time never reaches the log.
        #expect(CLIRefreshStatus.ok(lastRun: later).logName == CLIRefreshStatus.ok(lastRun: nil).logName)
        #expect(
            CLIRefreshStatus.unsupportedVersion(path: "/a/b", version: "1").logName
                == CLIRefreshStatus.unsupportedVersion(path: nil, version: nil).logName)
        #expect(CLIRefreshStatus.failed(.timedOut).logName == "failed(timedOut)")
        #expect(CLIRefreshStatus.disabledForSafety(.modelCall).logName == "disabledForSafety(modelCall)")
    }

    @Test func autoRefreshOutcomeNamesAreDistinctAndSafe() {
        var outcomes: [CLIRefreshOutcome] = [.success, .modelCallDetected, .notLoggedIn]
        outcomes += CLIRefreshFailure.allCases.map { .failed($0) }
        let names = outcomes.map(\.logName)

        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy(isSafe))
        #expect(CLIRefreshOutcome.modelCallDetected.logName == "modelCallDetected")
    }
}
