import Foundation
import QuotaRingCore
import Testing

/// What the menu bar item shows and says for a state of the model at a moment. Text that comes from a formatter uses
/// the same formatter in the expectation (so the tests hold in any language of the machine); the words around it are
/// the English ones, because the test bundle has no translations.
@MainActor
@Suite struct StatusPresentationTests {
    private let now = Date()

    private func percent(_ value: Double) -> String { QuotaFormat.percent(value) }

    private func spoken(until moment: Date) -> String { QuotaFormat.spokenCountdown(to: moment, from: now) }

    /// Builds the presentation for `snapshot` after `setUp` changed the settings; `live` also turns Live mode on.
    private func present(
        _ snapshot: UsageSnapshot?,
        live: LiveStatus? = nil,
        setUp: (SettingsStore) -> Void = { _ in }
    ) throws -> StatusPresentation {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        setUp(rig.settings)
        if let live {
            rig.enableLiveMode()
            rig.model.handle(.liveStatus(live))
        }
        if let snapshot {
            rig.model.handle(.snapshot(snapshot, isNew: false))
        }
        return StatusPresentation(model: rig.model, now: now)
    }

    // MARK: - No data

    @Test func withoutAnyDataTheRingIsEmptyAndHasNoText() throws {
        let presentation = try present(nil)

        #expect(presentation.fraction == nil)
        #expect(presentation.text == nil)
        #expect(!presentation.isTextDimmed)
        #expect(presentation.style == RingStyle())
        #expect(presentation.accessibilityLabel == "QuotaRing: no usage data yet")
    }

    @Test func aSnapshotWithoutASessionLimitCountsAsNoData() throws {
        let presentation = try present(TestData.snapshotWithoutSession(now: now))

        #expect(presentation.fraction == nil)
        #expect(presentation.text == nil)
        #expect(presentation.accessibilityLabel == "QuotaRing: no usage data yet")
    }

    // MARK: - Fresh numbers

    @Test func freshNumbersShowWhatIsLeftByDefault() throws {
        let presentation = try present(TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 8_040))

        #expect(try #require(presentation.fraction) == 0.6)
        #expect(presentation.text == percent(60))
        #expect(!presentation.isTextDimmed)
        #expect(presentation.style == RingStyle())
        #expect(
            presentation.accessibilityLabel
                == "QuotaRing: \(percent(60)) of 5-hour limit remaining, resets in \(spoken(until: now.addingTimeInterval(8_040)))"
        )
    }

    @Test func theRingCanShowTheUsedShareInstead() throws {
        let presentation = try present(TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 8_040)) {
            $0.ringShowsRemaining = false
        }

        #expect(try #require(presentation.fraction) == 0.4)
        #expect(presentation.text == percent(40))
        // The tint still follows what is left, not what is shown.
        #expect(presentation.style.tint == .standard)
        #expect(
            presentation.accessibilityLabel
                == "QuotaRing: \(percent(40)) of 5-hour limit used, resets in \(spoken(until: now.addingTimeInterval(8_040)))"
        )
    }

    @Test func withoutAResetTimeTheLabelHasNoCountdown() throws {
        let remaining = try present(TestData.snapshot(now: now, sessionUsed: 25, resetsIn: nil))
        #expect(remaining.accessibilityLabel == "QuotaRing: \(percent(75)) of 5-hour limit remaining")

        let used = try present(TestData.snapshot(now: now, sessionUsed: 25, resetsIn: nil)) {
            $0.ringShowsRemaining = false
        }
        #expect(used.accessibilityLabel == "QuotaRing: \(percent(25)) of 5-hour limit used")
    }

    @Test func thePercentageTextCanBeSwitchedOff() throws {
        let hidden = try present(TestData.snapshot(now: now, sessionUsed: 40)) { $0.showPercentText = false }

        #expect(hidden.text == nil)
        // The ring and the spoken label are not affected.
        #expect(try #require(hidden.fraction) == 0.6)
        #expect(hidden.accessibilityLabel.contains(percent(60)))
    }

    @Test(arguments: [
        (used: 0.0, tint: RingStyle.Tint.standard),
        (used: 79.0, tint: .standard),
        (used: 79.9, tint: .standard),
        (used: 80.0, tint: .warning),
        (used: 94.0, tint: .warning),
        (used: 95.0, tint: .critical),
        (used: 100.0, tint: .critical),
    ])
    func theTintFollowsWhatIsLeft(used: Double, tint: RingStyle.Tint) throws {
        for showsRemaining in [true, false] {
            let presentation = try present(TestData.snapshot(now: now, sessionUsed: used)) {
                $0.ringShowsRemaining = showsRemaining
            }
            #expect(presentation.style.tint == tint, "\(used) used, remaining shown: \(showsRemaining)")
        }
    }

    @Test func aWindowThatResetAfterTheReadingShowsAFullRingWhileTheNumbersAreFresh() throws {
        // Fetched 30 seconds ago, but the window it describes ended 10 seconds ago: the old percentage no longer applies.
        let presentation = try present(TestData.snapshot(now: now, sessionUsed: 90, resetsIn: -10, fetchedAgo: 30))

        #expect(try #require(presentation.fraction) == 1)
        #expect(presentation.text == percent(100))
        #expect(!presentation.style.isStale)
        #expect(presentation.style.tint == .standard)
        #expect(presentation.accessibilityLabel == "QuotaRing: \(percent(100)) of 5-hour limit remaining")
    }

    @Test(arguments: [(used: 150.0, shown: 0.0), (used: -20.0, shown: 1.0), (used: Double.nan, shown: 0.0)])
    func numbersOutsideTheRangeNeverLeaveTheRing(used: Double, shown: Double) throws {
        let presentation = try present(TestData.snapshot(now: now, sessionUsed: used))

        let fraction = try #require(presentation.fraction)
        #expect((0...1).contains(fraction))
        #expect(fraction == shown)
        #expect(presentation.text == percent(shown * 100))
    }

    // MARK: - Old numbers

    @Test func oldNumbersAreDashedDimmedAndSaySoOutLoud() throws {
        // Older than twice the 5-minute interval, session still running.
        let snapshot = TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 3_600, fetchedAgo: 3 * 3_600)
        let presentation = try present(snapshot)

        #expect(presentation.style.isStale)
        #expect(presentation.isTextDimmed)
        #expect(try #require(presentation.fraction) == 0.6)
        #expect(presentation.text == percent(60))
        let age = QuotaFormat.age(of: snapshot.fetchedAt, now: now)
        #expect(presentation.accessibilityLabel.hasSuffix(". Out of date, last updated \(age)."))
        #expect(presentation.accessibilityLabel.hasPrefix("QuotaRing: \(percent(60)) of 5-hour limit remaining"))
    }

    @Test func numbersJustWithinTheLimitAreNotOld() throws {
        let fresh = try present(TestData.snapshot(now: now, fetchedAgo: 600))
        #expect(!fresh.style.isStale)
        let stale = try present(TestData.snapshot(now: now, fetchedAgo: 601))
        #expect(stale.style.isStale)
    }

    @Test func oldNumbersOfAWindowThatEndedShowADashAndNoRingFill() throws {
        let snapshot = TestData.snapshot(now: now, sessionUsed: 90, resetsIn: -3_600, fetchedAgo: 3 * 3_600)
        let presentation = try present(snapshot)

        #expect(presentation.fraction == nil)
        #expect(presentation.text == "–")
        #expect(presentation.isTextDimmed)
        #expect(presentation.style.isStale)
        // No tint from the old percentage.
        #expect(presentation.style.tint == .standard)
        let age = QuotaFormat.age(of: snapshot.fetchedAt, now: now)
        #expect(
            presentation.accessibilityLabel
                == "QuotaRing: the 5-hour session has reset, waiting for fresh data. Out of date, last updated \(age)."
        )
    }

    @Test func theDashIsLeftOutWhenThePercentageTextIsOff() throws {
        let snapshot = TestData.snapshot(now: now, sessionUsed: 90, resetsIn: -3_600, fetchedAgo: 3 * 3_600)
        let presentation = try present(snapshot) { $0.showPercentText = false }

        #expect(presentation.fraction == nil)
        #expect(presentation.text == nil)
        #expect(presentation.style.isStale)
    }

    @Test func theDashDoesNotDependOnWhatTheRingShows() throws {
        let snapshot = TestData.snapshot(now: now, sessionUsed: 90, resetsIn: -3_600, fetchedAgo: 3 * 3_600)
        let used = try present(snapshot) { $0.ringShowsRemaining = false }

        #expect(used.fraction == nil)
        #expect(used.text == "–")
    }

    // MARK: - Live mode needs attention

    @Test(arguments: [LiveStatus.expired, .noCredential, .keychainDenied, .error])
    func aLiveModeThatCannotFetchPutsADotOnTheRingAndSaysSo(status: LiveStatus) throws {
        let withData = try present(TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 3_600), live: status)
        #expect(withData.style.needsAttention)
        #expect(withData.accessibilityLabel.hasSuffix(". Live mode needs attention."))
        #expect(try #require(withData.fraction) == 0.6)

        // Also before any number is known.
        let withoutData = try present(nil, live: status)
        #expect(withoutData.style.needsAttention)
        #expect(withoutData.fraction == nil)
        #expect(withoutData.accessibilityLabel == "QuotaRing: no usage data yet")
    }

    @Test(arguments: [LiveStatus.off, .ok, .rateLimited(until: Date(timeIntervalSince1970: 1_792_600_000))])
    func aLiveModeThatIsFineOrJustWaitingNeedsNoAttention(status: LiveStatus) throws {
        let presentation = try present(TestData.snapshot(now: now), live: status)

        #expect(!presentation.style.needsAttention)
        #expect(!presentation.accessibilityLabel.contains("Live mode needs attention"))
    }

    @Test func aProblemOfLiveModeIsIgnoredWhileLiveModeIsOff() throws {
        // Stale status, but no consent (or no finished welcome window): nothing to attend to.
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.model.handle(.liveStatus(.expired))
        rig.model.handle(.snapshot(TestData.snapshot(now: now), isNew: false))

        let presentation = StatusPresentation(model: rig.model, now: now)
        #expect(!presentation.style.needsAttention)

        // Consent without a finished welcome window is not active either.
        rig.settings.liveModeEnabled = true
        #expect(!StatusPresentation(model: rig.model, now: now).style.needsAttention)

        rig.settings.hasCompletedOnboarding = true
        #expect(StatusPresentation(model: rig.model, now: now).style.needsAttention)
    }

    @Test func oldNumbersMentionLiveModeInsideTheOutOfDateNote() throws {
        let snapshot = TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 3_600, fetchedAgo: 3 * 3_600)
        let presentation = try present(snapshot, live: .expired)

        let age = QuotaFormat.age(of: snapshot.fetchedAt, now: now)
        #expect(presentation.style.needsAttention)
        #expect(
            presentation.accessibilityLabel.hasSuffix(". Out of date, last updated \(age). Live mode needs attention."))
        // Said once, not once for the age and once for the dot.
        #expect(presentation.accessibilityLabel.components(separatedBy: "Live mode needs attention").count == 2)
    }

    @Test func aResetWindowWithOldNumbersAlsoMentionsLiveMode() throws {
        let snapshot = TestData.snapshot(now: now, sessionUsed: 90, resetsIn: -3_600, fetchedAgo: 3 * 3_600)
        let presentation = try present(snapshot, live: .keychainDenied)

        #expect(presentation.fraction == nil)
        #expect(presentation.style.needsAttention)
        #expect(presentation.accessibilityLabel.hasSuffix("Live mode needs attention."))
        #expect(presentation.accessibilityLabel.components(separatedBy: "Live mode needs attention").count == 2)
    }

    // MARK: - Demo

    @Test func theDemoDataLooksLikeTheDocumentedScreenshot() throws {
        let rig = try ModelRig(demo: true)
        defer { rig.sandbox.remove() }

        let presentation = StatusPresentation(model: rig.model, now: Date())

        #expect(try #require(presentation.fraction) == 0.72)
        #expect(presentation.text == percent(72))
        #expect(presentation.style == RingStyle())
        #expect(!presentation.isTextDimmed)
    }
}
