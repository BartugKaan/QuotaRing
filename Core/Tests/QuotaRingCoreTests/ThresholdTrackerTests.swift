import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct ThresholdTrackerTests {
    /// Two readings of the same reset instant as returned by the live API: the microseconds jitter between calls and
    /// straddle the whole second, but both round to the same minute.
    private let resetA = Date(timeIntervalSince1970: 1_792_623_000.192966)
    private let resetB = Date(timeIntervalSince1970: 1_792_622_999.972394)
    private let before = Date(timeIntervalSince1970: 1_792_600_000)

    @Test func jitteredResetTimeIsSameWindow() {
        var tracker = ThresholdTracker()
        #expect(
            tracker.observe(percentUsed: 85, resetsAt: resetA, thresholds: [80, 95], now: before) == [.crossed(80)]
        )
        #expect(tracker.observe(percentUsed: 86, resetsAt: resetB, thresholds: [80, 95], now: before) == [])
    }

    @Test func crossesHigherLater() {
        var tracker = ThresholdTracker()
        #expect(
            tracker.observe(percentUsed: 85, resetsAt: resetA, thresholds: [80, 95], now: before) == [.crossed(80)]
        )
        #expect(
            tracker.observe(percentUsed: 96, resetsAt: resetB, thresholds: [80, 95], now: before) == [.crossed(95)]
        )
        #expect(tracker.observe(percentUsed: 97, resetsAt: resetA, thresholds: [80, 95], now: before) == [])
    }

    @Test func firstObservationFiresEveryExceededThreshold() {
        var tracker = ThresholdTracker()
        let events = tracker.observe(percentUsed: 97, resetsAt: resetA, thresholds: [95, 80], now: before)
        #expect(events == [.crossed(80), .crossed(95)])
        #expect(tracker.observe(percentUsed: 97, resetsAt: resetA, thresholds: [95, 80], now: before) == [])
    }

    @Test func belowThresholdsEmitsNothing() {
        var tracker = ThresholdTracker()
        #expect(tracker.observe(percentUsed: 79.9, resetsAt: resetA, thresholds: [80, 95], now: before) == [])
        #expect(
            tracker.observe(percentUsed: 80, resetsAt: resetA, thresholds: [80, 95], now: before) == [.crossed(80)]
        )
    }

    @Test func newWindowEmitsReset() {
        var tracker = ThresholdTracker()
        #expect(
            tracker.observe(percentUsed: 90, resetsAt: resetA, thresholds: [80, 95], now: before) == [.crossed(80)]
        )

        // The next window opens after the previous reset time has passed.
        let nextReset = resetA.addingTimeInterval(5 * 3600)
        let after = resetA.addingTimeInterval(120)
        #expect(tracker.observe(percentUsed: 4, resetsAt: nextReset, thresholds: [80, 95], now: after) == [.reset])

        // Thresholds re-arm in the new window.
        #expect(
            tracker.observe(percentUsed: 82, resetsAt: nextReset, thresholds: [80, 95], now: after) == [.crossed(80)]
        )
    }

    @Test func newWindowBeforeOldOneElapsedDoesNotEmitReset() {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 90, resetsAt: resetA, thresholds: [80], now: before)

        // A different reset time while the old one is still in the future is not a reset, but it re-arms thresholds.
        let moved = resetA.addingTimeInterval(3600)
        #expect(tracker.observe(percentUsed: 90, resetsAt: moved, thresholds: [80], now: before) == [.crossed(80)])
    }

    @Test func resetAndCrossingInSameObservation() {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 50, resetsAt: resetA, thresholds: [80], now: before)

        let nextReset = resetA.addingTimeInterval(5 * 3600)
        let after = resetA.addingTimeInterval(120)
        #expect(
            tracker.observe(percentUsed: 85, resetsAt: nextReset, thresholds: [80], now: after)
                == [.reset, .crossed(80)]
        )
    }

    @Test func missingResetTimeEmitsNothing() {
        var tracker = ThresholdTracker()
        #expect(tracker.observe(percentUsed: 99, resetsAt: nil, thresholds: [80, 95], now: before) == [])

        // And it does not disturb an existing window.
        _ = tracker.observe(percentUsed: 85, resetsAt: resetA, thresholds: [80, 95], now: before)
        #expect(tracker.observe(percentUsed: 99, resetsAt: nil, thresholds: [80, 95], now: before) == [])
        #expect(tracker.observe(percentUsed: 86, resetsAt: resetB, thresholds: [80, 95], now: before) == [])
    }

    @Test func survivesPersistence() throws {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 85, resetsAt: resetA, thresholds: [80, 95], now: before)

        let data = try JSONEncoder().encode(tracker)
        var restored = try JSONDecoder().decode(ThresholdTracker.self, from: data)
        #expect(restored == tracker)
        #expect(restored.observe(percentUsed: 86, resetsAt: resetB, thresholds: [80, 95], now: before) == [])
        #expect(
            restored.observe(percentUsed: 96, resetsAt: resetB, thresholds: [80, 95], now: before) == [.crossed(95)]
        )
    }

    // MARK: - Time-driven reset

    @Test func windowEndAnnouncesTheResetOnceWithoutNewData() {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 90, resetsAt: resetA, thresholds: [80, 95], now: before)

        // Before the reset time nothing happens.
        #expect(tracker.observeWindowEnd(now: before) == [])
        #expect(tracker.observeWindowEnd(now: resetA.addingTimeInterval(-60)) == [])

        // After it, the 30 s tick announces the reset once.
        let after = resetA.addingTimeInterval(30)
        #expect(tracker.observeWindowEnd(now: after) == [.reset])
        #expect(tracker.observeWindowEnd(now: after.addingTimeInterval(30)) == [])
    }

    @Test func dataAfterATimeDrivenResetDoesNotAnnounceItAgain() {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 90, resetsAt: resetA, thresholds: [80, 95], now: before)
        let after = resetA.addingTimeInterval(30)
        #expect(tracker.observeWindowEnd(now: after) == [.reset])

        // The next window's first reading: no second reset, and the thresholds are armed again.
        let nextReset = resetA.addingTimeInterval(5 * 3600)
        let later = resetA.addingTimeInterval(600)
        #expect(
            tracker.observe(percentUsed: 85, resetsAt: nextReset, thresholds: [80, 95], now: later) == [.crossed(80)])
        #expect(tracker.observeWindowEnd(now: later) == [])
    }

    @Test func dataBeforeTheTickAnnouncesTheResetOnlyOnce() {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 90, resetsAt: resetA, thresholds: [80], now: before)

        // New data arrives first (the reading reports the reset); the tick then finds a window still open.
        let nextReset = resetA.addingTimeInterval(5 * 3600)
        let after = resetA.addingTimeInterval(30)
        #expect(tracker.observe(percentUsed: 2, resetsAt: nextReset, thresholds: [80], now: after) == [.reset])
        #expect(tracker.observeWindowEnd(now: after) == [])
    }

    @Test func windowEndWithoutAnyReadingDoesNothing() {
        var tracker = ThresholdTracker()
        #expect(tracker.observeWindowEnd(now: before) == [])
    }

    @Test func closedWindowSurvivesPersistence() throws {
        var tracker = ThresholdTracker()
        _ = tracker.observe(percentUsed: 90, resetsAt: resetA, thresholds: [80], now: before)
        let after = resetA.addingTimeInterval(30)
        #expect(tracker.observeWindowEnd(now: after) == [.reset])

        var restored = try JSONDecoder().decode(ThresholdTracker.self, from: JSONEncoder().encode(tracker))
        #expect(restored.observeWindowEnd(now: after) == [])
        let nextReset = resetA.addingTimeInterval(5 * 3600)
        #expect(restored.observe(percentUsed: 1, resetsAt: nextReset, thresholds: [80], now: after) == [])
    }
}
