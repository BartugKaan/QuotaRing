import Foundation
import QuotaRingCore
import Testing

/// Which parts of the menu bar button a new presentation touches. Touching the button is what costs: the 30 s tick must
/// leave it alone when nothing it shows has changed.
@Suite struct StatusButtonStateTests {
    private func presentation(
        fraction: Double? = 0.6,
        style: RingStyle = RingStyle(),
        text: String? = "60%",
        isTextDimmed: Bool = false,
        label: String = "QuotaRing: 60% of 5-hour limit remaining, resets in 2 hours"
    ) -> StatusPresentation {
        StatusPresentation(
            fraction: fraction, style: style, text: text, isTextDimmed: isTextDimmed, accessibilityLabel: label)
    }

    /// A state that has shown `shown`, so that the next update is a repeat or a change.
    private func state(having shown: StatusPresentation) -> StatusButtonState {
        var state = StatusButtonState()
        _ = state.update(to: shown)
        return state
    }

    @Test func theFirstPresentationTouchesEverything() {
        var state = StatusButtonState()
        #expect(state.update(to: presentation()) == .all)
    }

    @Test func theFirstPresentationWithoutDataTouchesEverythingToo() {
        var state = StatusButtonState()
        let empty = presentation(fraction: nil, text: nil, label: "QuotaRing: no usage data yet")
        #expect(state.update(to: empty) == .all)
    }

    @Test func aRepeatedPresentationTouchesNothing() {
        var state = state(having: presentation())
        #expect(state.update(to: presentation()) == [])
        #expect(state.update(to: presentation()) == [])
    }

    @Test func aChangedFractionTouchesOnlyTheImage() {
        var state = state(having: presentation())
        #expect(state.update(to: presentation(fraction: 0.59)) == .image)
    }

    @Test(arguments: [
        RingStyle(tint: .warning),
        RingStyle(tint: .critical),
        RingStyle(isStale: true),
        RingStyle(needsAttention: true),
    ])
    func aChangedStyleTouchesOnlyTheImage(style: RingStyle) {
        var state = state(having: presentation())
        #expect(state.update(to: presentation(style: style)) == .image)
        // And back.
        #expect(state.update(to: presentation()) == .image)
    }

    @Test func aRingThatLosesItsFractionTouchesOnlyTheImage() {
        var state = state(having: presentation())
        #expect(state.update(to: presentation(fraction: nil)) == .image)
        #expect(state.update(to: presentation(fraction: 0)) == .image)
    }

    @Test func aChangedTextTouchesOnlyTheTitle() {
        var state = state(having: presentation())
        #expect(state.update(to: presentation(text: "59%")) == .title)
    }

    @Test func dimmingTheTextTouchesOnlyTheTitle() {
        var state = state(having: presentation())
        #expect(state.update(to: presentation(isTextDimmed: true)) == .title)
        #expect(state.update(to: presentation(isTextDimmed: true)) == [])
        #expect(state.update(to: presentation(isTextDimmed: false)) == .title)
    }

    @Test func showingOrHidingTheTextTouchesOnlyTheTitle() {
        // The title also decides where the image sits (alone, or before the text).
        var state = state(having: presentation())
        #expect(state.update(to: presentation(text: nil)) == .title)
        #expect(state.update(to: presentation(text: "60%")) == .title)
    }

    @Test func aChangedLabelTouchesOnlyTheAccessibilityLabelAndTooltip() {
        // What the minute-by-minute countdown does.
        var state = state(having: presentation())
        #expect(
            state.update(to: presentation(label: "QuotaRing: 60% of 5-hour limit remaining, resets in 1 hour"))
                == .accessibility)
    }

    @Test func severalChangesAreReportedTogether() {
        var state = state(having: presentation())
        let changes = state.update(
            to: presentation(fraction: 0.2, style: RingStyle(tint: .warning), text: "20%", label: "low"))
        #expect(changes == .all)
        let partly = state.update(
            to: presentation(fraction: 0.2, style: RingStyle(tint: .warning), text: "19%", label: "low"))
        #expect(partly == .title)
    }

    @Test func eachChangeIsComparedWithWhatTheButtonShowsNow() {
        // A then B then A again: the second A differs from B, not from the first A.
        var state = state(having: presentation(text: "60%"))
        #expect(state.update(to: presentation(text: "50%")) == .title)
        #expect(state.update(to: presentation(text: "60%")) == .title)
    }

    @Test func aFractionThatIsNotANumberIsTheSameEmptyRingEveryTime() {
        var state = StatusButtonState()
        _ = state.update(to: presentation(fraction: .nan))
        #expect(state.update(to: presentation(fraction: .nan)) == [])
        // The renderer draws it as an empty arc, so it equals zero.
        #expect(state.update(to: presentation(fraction: 0)) == [])
    }

    // MARK: - From the model

    @MainActor
    @Test func aTickThatChangesNothingTouchesNothingAndTheCountdownTouchesOnlyTheLabel() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let now = Date()
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 8_040), isNew: false))
        var state = StatusButtonState()
        #expect(state.update(to: StatusPresentation(model: rig.model, now: now)) == .all)

        // Same minute of the countdown, same numbers: nothing to do, the tick costs nothing.
        #expect(state.update(to: StatusPresentation(model: rig.model, now: now)) == [])
        // The countdown in the label moved on; the ring and the text did not.
        let later = state.update(to: StatusPresentation(model: rig.model, now: now.addingTimeInterval(180)))
        #expect(later == .accessibility)
    }

    @MainActor
    @Test func newDataTouchesTheRingAndTheText() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let now = Date()
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 40, resetsIn: 8_040), isNew: false))
        var state = StatusButtonState()
        _ = state.update(to: StatusPresentation(model: rig.model, now: now))

        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 55, resetsIn: 8_040), isNew: true))
        let changes = state.update(to: StatusPresentation(model: rig.model, now: now))

        #expect(changes.contains(.image))
        #expect(changes.contains(.title))
    }

    @MainActor
    @Test func staleDataDimsTheTextAndDashesTheRing() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let now = Date()
        rig.model.handle(.snapshot(TestData.snapshot(now: now, resetsIn: 8_040, fetchedAgo: 30), isNew: false))
        var state = StatusButtonState()
        _ = state.update(to: StatusPresentation(model: rig.model, now: now))

        // The same snapshot, an hour on: older than two refresh intervals.
        let changes = state.update(to: StatusPresentation(model: rig.model, now: now.addingTimeInterval(3_600)))

        #expect(changes.contains(.image))
        #expect(changes.contains(.title))
        #expect(changes.contains(.accessibility))
    }
}
