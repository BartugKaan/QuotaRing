import CoreGraphics
import Testing

@MainActor
@Suite struct VisibleScreenTests {
    @Test func theContentGetsWhatIsLeftOfTheScreenAfterTheChromeAndAMargin() {
        // 900 high, 330 of title bar and buttons, 40 of margin.
        #expect(VisibleScreen.contentHeight(reserving: 330, visibleHeight: 900) == 530)
        #expect(VisibleScreen.contentHeight(reserving: 0, visibleHeight: 800) == 760)
    }

    @Test func aShortScreenStillLeavesRoomToScroll() {
        #expect(VisibleScreen.contentHeight(reserving: 330, visibleHeight: 400) == 240)
        #expect(VisibleScreen.contentHeight(reserving: 1_000, visibleHeight: 600) == 240)
        #expect(VisibleScreen.contentHeight(reserving: 0, visibleHeight: 0) == 240)
        #expect(VisibleScreen.contentHeight(reserving: 0, visibleHeight: -50) == 240)
    }

    @Test func theMinimumStartsExactlyWhereTheRoomRunsOut() {
        // 240 + 330 + 40 = 610 is the smallest screen that gives more than the minimum.
        #expect(VisibleScreen.contentHeight(reserving: 330, visibleHeight: 610) == 240)
        #expect(VisibleScreen.contentHeight(reserving: 330, visibleHeight: 611) == 241)
        #expect(VisibleScreen.contentHeight(reserving: 330, visibleHeight: 609) == 240)
    }

    @Test func aTallerScreenGivesMoreRoom() {
        let small = VisibleScreen.contentHeight(reserving: 330, visibleHeight: 800)
        let large = VisibleScreen.contentHeight(reserving: 330, visibleHeight: 1_200)
        #expect(large - small == 400)
    }

    @Test func theMainScreenIsUsedWhenNoHeightIsGiven() {
        // Whatever this machine's screen is (or a fallback when it has none), the answer is usable.
        let height = VisibleScreen.contentHeight(reserving: 330)
        #expect(height >= 240)
        #expect(height.isFinite)
    }
}
