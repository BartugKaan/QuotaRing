import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct CacheReadHealthTests {
    private let start = Date(timeIntervalSince1970: 1_792_600_000)

    @Test func healthyByDefaultAndAfterSuccess() {
        var health = CacheReadHealth()
        #expect(health.problem(at: start) == nil)

        health.recordFailure(.unreadable, at: start)
        #expect(health.problem(at: start) == .unreadable)
        health.recordSuccess()
        #expect(health.problem(at: start) == nil)
        #expect(health.lastError == nil)
        #expect(health.failingSince == nil)
    }

    @Test func tooLargeAndUnreadableAreReportedAtOnce() {
        for error: CacheReadError in [.fileTooLarge, .unreadable] {
            var health = CacheReadHealth()
            health.recordFailure(error, at: start)
            #expect(health.problem(at: start) == error)
        }
    }

    @Test func malformedIsReportedOnlyWhenItPersists() {
        // A torn read while Claude Code rewrites the file is normal and must not flash a warning.
        var health = CacheReadHealth()
        health.recordFailure(.malformed, at: start)
        #expect(health.problem(at: start) == nil)
        #expect(health.problem(at: start.addingTimeInterval(89)) == nil)
        #expect(health.problem(at: start.addingTimeInterval(CacheReadHealth.malformedGracePeriod)) == .malformed)

        // Further malformed reads do not restart the clock.
        health.recordFailure(.malformed, at: start.addingTimeInterval(60))
        #expect(health.problem(at: start.addingTimeInterval(90)) == .malformed)

        // A good read in between does.
        health.recordSuccess()
        health.recordFailure(.malformed, at: start.addingTimeInterval(100))
        #expect(health.problem(at: start.addingTimeInterval(120)) == nil)
    }

    @Test func aWorseErrorAfterMalformedIsReportedAtOnce() {
        var health = CacheReadHealth()
        health.recordFailure(.malformed, at: start)
        health.recordFailure(.fileTooLarge, at: start.addingTimeInterval(30))
        #expect(health.problem(at: start.addingTimeInterval(30)) == .fileTooLarge)
        #expect(health.failingSince == start)
    }

    @Test func accountMismatchIsNotAReadProblem() {
        var health = CacheReadHealth()
        health.recordFailure(.unreadable, at: start)
        health.recordFailure(.accountMismatch, at: start.addingTimeInterval(10))
        #expect(health.problem(at: start.addingTimeInterval(10)) == nil)
        #expect(health.lastError == nil)
    }
}
