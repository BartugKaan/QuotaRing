import Foundation
import QuotaRingCore
import Testing

/// What the popover's "no usage data yet" section offers under its text. The view is not rendered (a hostless test
/// has no application to host it); the decision is `NoDataSection.offer`.
@MainActor
@Suite struct NoDataSectionTests {
    private func section(
        live: Bool = false, liveStatus: LiveStatus = .off, cli: Bool = false, cliStatus: CLIRefreshStatus = .off,
        needsOnboarding: Bool = false, showWelcomeWindow: @escaping () -> Void = {}
    ) -> NoDataSection {
        NoDataSection(
            isLiveModeActive: live, liveStatus: liveStatus, isCLIRefreshActive: cli, cliStatus: cliStatus,
            needsOnboarding: needsOnboarding, now: Date(), openDataSettings: {}, showWelcomeWindow: showWelcomeWindow)
    }

    // MARK: - Before the welcome window is finished

    @Test func anUnfinishedWelcomeWindowOffersOnlyThatWindow() {
        #expect(section(needsOnboarding: true).offer == .welcomeWindow)
    }

    @Test func theWelcomeWindowComesBeforeEverythingElse() {
        let states: [(live: Bool, liveStatus: LiveStatus, cli: Bool, cliStatus: CLIRefreshStatus)] = [
            (false, .off, false, .off),
            (true, .ok, false, .off),
            (true, .expired, false, .off),
            (false, .off, true, .ok(lastRun: nil)),
            (false, .off, true, .notFound),
            (false, .off, false, .disabledForSafety(.modelCall)),
            (true, .keychainDenied, true, .failed(.timedOut)),
        ]
        for state in states {
            let shown = section(
                live: state.live, liveStatus: state.liveStatus, cli: state.cli, cliStatus: state.cliStatus,
                needsOnboarding: true)
            #expect(shown.offer == .welcomeWindow, "\(state)")
        }
    }

    @Test func theWelcomeWindowButtonIsWiredToItsAction() {
        var shown = 0
        let section = section(needsOnboarding: true, showWelcomeWindow: { shown += 1 })

        section.showWelcomeWindow()

        #expect(shown == 1)
    }

    @Test func byDefaultNothingWaitsForTheWelcomeWindow() {
        let plain = section()
        #expect(!plain.needsOnboarding)
        // The default action does nothing and may be called.
        plain.showWelcomeWindow()
    }

    // MARK: - Neither Live mode nor auto-refresh

    @Test func withBothOffSettingsIsOfferedWithBothWays() {
        #expect(section().offer == .turnOn(includingAutoRefresh: true))
        #expect(section(cliStatus: .notFound).offer == .turnOn(includingAutoRefresh: true))
    }

    @Test(arguments: CLISafetyStop.allCases)
    func afterASafetySwitchOffAutoRefreshIsNotSuggestedAgain(reason: CLISafetyStop) {
        #expect(section(cliStatus: .disabledForSafety(reason)).offer == .turnOn(includingAutoRefresh: false))
    }

    // MARK: - Something is on

    @Test func aWorkingLiveModeWaitsForTheFirstReading() {
        #expect(section(live: true, liveStatus: .ok).offer == .waiting)
        #expect(section(live: true, liveStatus: .off).offer == .waiting)
        #expect(!section(live: true, liveStatus: .ok).needsAttention)
    }

    @Test(arguments: [LiveStatus.expired, .noCredential, .keychainDenied, .error])
    func aLiveModeThatCannotFetchOffersNothingBecauseTheTextSaysWhatToDo(status: LiveStatus) {
        let shown = section(live: true, liveStatus: status)
        #expect(shown.needsAttention)
        #expect(shown.offer == .nothing)
    }

    @Test func aRateLimitedLiveModeNeedsAttentionToo() {
        let shown = section(live: true, liveStatus: .rateLimited(until: Date().addingTimeInterval(120)))
        #expect(shown.needsAttention)
        #expect(shown.offer == .nothing)
    }

    @Test func autoRefreshAloneWaitsWhileItIsFine() {
        for status: CLIRefreshStatus in [.off, .ok(lastRun: nil), .ok(lastRun: Date()), .running] {
            let shown = section(cli: true, cliStatus: status)
            #expect(shown.showsAutoRefresh)
            #expect(shown.offer == .waiting, "\(status)")
        }
    }

    @Test func autoRefreshAloneThatCannotRunOffersNothing() {
        var problems: [CLIRefreshStatus] = [
            .notFound, .notLoggedIn, .unsupportedVersion(path: nil, version: "1.0.0"),
        ]
        problems += CLIRefreshFailure.allCases.map { .failed($0) }
        problems += CLISafetyStop.allCases.map { .disabledForSafety($0) }
        for status in problems {
            let shown = section(cli: true, cliStatus: status)
            #expect(shown.needsAttention)
            #expect(shown.offer == .nothing, "\(status)")
        }
    }

    @Test func whenBothAreOnLiveModeDecidesAndAutoRefreshStatusIsNotConsulted() {
        let live = section(live: true, liveStatus: .ok, cli: true, cliStatus: .notFound)
        #expect(!live.showsAutoRefresh)
        #expect(!live.needsAttention)
        #expect(live.offer == .waiting)

        let broken = section(live: true, liveStatus: .expired, cli: true, cliStatus: .ok(lastRun: nil))
        #expect(broken.needsAttention)
        #expect(broken.offer == .nothing)
    }

    @Test func aProblemOfAFeatureThatIsOffIsNotMistakenForAttention() {
        // The status of a switched-off Live mode can be stale; it does not matter while the consent is off.
        #expect(!section(live: false, liveStatus: .expired).needsAttention)
        #expect(section(live: false, liveStatus: .expired).offer == .turnOn(includingAutoRefresh: true))
    }
}
