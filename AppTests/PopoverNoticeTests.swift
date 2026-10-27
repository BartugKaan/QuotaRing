import Foundation
import QuotaRingCore
import Testing

/// What the popover says when an update changed what auto-refresh runs, so the user's earlier consent no longer counts.
@Suite struct PopoverNoticeTests {
    private let now = Date()

    private func notices(cliNeedsNewConsent: Bool, isStale: Bool) -> [PopoverNotice] {
        PopoverNotice.notices(
            liveStatus: .off, cliStatus: .off, isCLIRefreshActive: false, cliNeedsNewConsent: cliNeedsNewConsent,
            cacheProblem: nil, isStale: isStale, now: now)
    }

    @Test func anOutdatedConsentIsExplainedAndLeadsToSettings() {
        let shown = notices(cliNeedsNewConsent: true, isStale: false)
        #expect(shown.map(\.id) == ["autoRefreshChanged"])
        #expect(shown.first?.action == .turnOnAutoRefresh)
    }

    @Test func oldDataDoesNotOfferAutoRefreshASecondTime() {
        let shown = notices(cliNeedsNewConsent: true, isStale: true)
        #expect(shown.map(\.id) == ["autoRefreshChanged", "stale"])
        #expect(shown.compactMap(\.action) == [.turnOnAutoRefresh])
    }

    @Test func withoutAnOutdatedConsentOldDataOffersAutoRefresh() {
        let shown = notices(cliNeedsNewConsent: false, isStale: true)
        #expect(shown.map(\.id) == ["stale"])
        #expect(shown.first?.action == .turnOnAutoRefresh)
    }
}
