import Foundation
import QuotaRingCore
import Testing

/// What finishing the welcome window records and does. Each case spells out what the user should end up with; the
/// rules themselves are decided by `OnboardingPlan` (tested in Core), so these tests check that the model applies them
/// to the settings, the notification prompt and the Live gate, in the right order.
@MainActor
@Suite struct OnboardingModelTests {
    /// The clock of every test: the hold's deadline is exactly this plus 15 seconds.
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    private struct Rig {
        let sandbox: TestSandbox
        let settings: SettingsStore
        let gate: FakeLiveGate
        let prompt: FakePermissionPrompt
        let model: OnboardingModel
    }

    private func rig(
        notify: Bool = true, refresh: Bool = true, answersAtOnce: Bool = true, withGate: Bool = true
    ) throws -> Rig {
        let sandbox = try TestSandbox()
        let settings = sandbox.makeSettings()
        let gate = FakeLiveGate(settings: settings)
        let prompt = FakePermissionPrompt(answersAtOnce: answersAtOnce)
        let moment = now
        let model = OnboardingModel(
            settings: settings, liveGate: withGate ? gate : nil, requestNotificationPermission: prompt.request,
            now: { moment })
        model.notifyNearLimit = notify
        model.refreshWithClaudeCode = refresh
        return Rig(sandbox: sandbox, settings: settings, gate: gate, prompt: prompt, model: model)
    }

    // MARK: - Defaults

    @Test func theCheckboxesStartAsDocumented() throws {
        let rig = try rig()
        defer { rig.sandbox.remove() }
        let fresh = OnboardingModel(settings: rig.settings, liveGate: nil, requestNotificationPermission: {})

        #expect(fresh.notifyNearLimit)
        #expect(fresh.refreshWithClaudeCode)
        #expect(!fresh.isFinished)
        // Looking at the window changes nothing.
        #expect(!rig.settings.hasCompletedOnboarding)
        #expect(rig.sandbox.savedValues.isEmpty)
    }

    // MARK: - The two buttons

    @Test func enableLiveModeRecordsLiveModeAndTheCheckboxes() async throws {
        let rig = try rig(notify: true, refresh: true)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        #expect(rig.model.isFinished)
        #expect(rig.settings.hasCompletedOnboarding)
        #expect(rig.settings.liveModeEnabled)
        #expect(rig.settings.cliRefreshEnabled)
        #expect(rig.settings.isLiveModeActive)
        #expect(rig.settings.isCLIRefreshActive)
        #expect(rig.settings.notificationThresholds == [80, 95])
        #expect(await eventually { rig.prompt.finished == 1 })
    }

    @Test func useWithoutLiveModeLeavesLiveModeOffButKeepsTheCheckboxes() async throws {
        let rig = try rig(notify: true, refresh: true)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: false)

        #expect(rig.settings.hasCompletedOnboarding)
        #expect(!rig.settings.liveModeEnabled)
        #expect(!rig.settings.isLiveModeActive)
        #expect(rig.settings.cliRefreshEnabled)
        #expect(rig.settings.isCLIRefreshActive)
        #expect(rig.settings.notificationThresholds == [80, 95])
        #expect(await eventually { rig.prompt.finished == 1 })
    }

    @Test func theConsentIsRecordedForTheCurrentVersions() throws {
        let rig = try rig(notify: false, refresh: true)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        #expect(rig.settings.liveModeConsentVersion == UsageAPI.consentVersion)
        #expect(rig.settings.cliRefreshConsentVersion == CLIRefreshCommand.consentVersion)
        #expect(rig.sandbox.savedValues["liveModeConsentVersion"] as? Int == UsageAPI.consentVersion)
        #expect(rig.sandbox.savedValues["cliRefreshConsentVersion"] as? Int == CLIRefreshCommand.consentVersion)
        // So a relaunch of the same build finds both still on.
        let relaunched = rig.sandbox.makeSettings()
        #expect(relaunched.isLiveModeActive)
        #expect(relaunched.isCLIRefreshActive)
    }

    @Test func uncheckedBoxesAreRecordedAsOff() throws {
        let rig = try rig(notify: false, refresh: false)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        #expect(rig.settings.liveModeEnabled)
        #expect(!rig.settings.cliRefreshEnabled)
        #expect(rig.settings.notificationThresholds.isEmpty)
        #expect(rig.settings.hasCompletedOnboarding)
    }

    @Test func existingThresholdsSurviveWhenNotificationsAreWanted() throws {
        let rig = try rig(notify: true)
        defer { rig.sandbox.remove() }
        rig.settings.notificationThresholds = [60, 90]

        rig.model.finish(enableLiveMode: false)

        #expect(rig.settings.notificationThresholds == [60, 90])
    }

    @Test func noThresholdsAreSetWhenNotificationsAreNotWanted() throws {
        let rig = try rig(notify: false)
        defer { rig.sandbox.remove() }
        rig.settings.notificationThresholds = [60, 90]

        rig.model.finish(enableLiveMode: false)

        #expect(rig.settings.notificationThresholds.isEmpty)
    }

    @Test func thresholdsComeBackAsTheDefaultsWhenNotificationsAreWantedAndNoneAreSet() throws {
        let rig = try rig(notify: true)
        defer { rig.sandbox.remove() }
        rig.settings.notificationThresholds = []

        rig.model.finish(enableLiveMode: false)

        #expect(rig.settings.notificationThresholds == SettingsStore.defaultNotificationThresholds)
    }

    // MARK: - Closing the window

    @Test func closingTheWindowRecordsLiveModeAndAutoRefreshOffWhateverTheBoxesShow() throws {
        let rig = try rig(notify: true, refresh: true)
        defer { rig.sandbox.remove() }

        // The close path passes `enableLiveMode: false`; even a stray `true` must not turn anything on.
        rig.model.finish(enableLiveMode: true, closedWindow: true)

        #expect(rig.model.isFinished)
        #expect(rig.settings.hasCompletedOnboarding)
        #expect(!rig.settings.liveModeEnabled)
        #expect(!rig.settings.cliRefreshEnabled)
        #expect(!rig.settings.isLiveModeActive)
        #expect(!rig.settings.isCLIRefreshActive)
        #expect(rig.gate.holds.isEmpty)
    }

    @Test func closingTheWindowWithTheUsualFlagIsTheSame() throws {
        let rig = try rig(notify: false, refresh: true)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: false, closedWindow: true)

        #expect(rig.settings.hasCompletedOnboarding)
        #expect(!rig.settings.liveModeEnabled)
        #expect(!rig.settings.cliRefreshEnabled)
    }

    // MARK: - Only once

    @Test func aSecondCallDoesNothing() async throws {
        let rig = try rig(notify: true, refresh: true)
        defer { rig.sandbox.remove() }
        rig.model.finish(enableLiveMode: false)
        try #require(await eventually { rig.prompt.finished == 1 })
        let savedAfterFirst = rig.sandbox.savedValues.keys.sorted()

        // The window's close handler runs after a button was pressed; the button's choice must stand.
        rig.model.finish(enableLiveMode: true)
        rig.model.finish(enableLiveMode: false, closedWindow: true)
        rig.model.notifyNearLimit = false
        rig.model.finish(enableLiveMode: true)
        try await Task.sleep(for: .milliseconds(50))

        #expect(!rig.settings.liveModeEnabled)
        #expect(rig.settings.cliRefreshEnabled)
        #expect(rig.settings.notificationThresholds == [80, 95])
        #expect(rig.prompt.calls == 1)
        #expect(rig.gate.holds.isEmpty)
        #expect(rig.gate.releases == 0)
        #expect(rig.sandbox.savedValues.keys.sorted() == savedAfterFirst)
    }

    @Test func aSecondCallAfterClosingCannotTurnLiveModeOn() throws {
        let rig = try rig()
        defer { rig.sandbox.remove() }
        rig.model.finish(enableLiveMode: false, closedWindow: true)

        rig.model.finish(enableLiveMode: true)

        #expect(!rig.settings.liveModeEnabled)
        #expect(!rig.settings.cliRefreshEnabled)
    }

    // MARK: - The notification prompt

    @Test func thePromptIsShownOnlyWhenTheBoxIsChecked() async throws {
        let wanted = try rig(notify: true)
        defer { wanted.sandbox.remove() }
        let unwanted = try rig(notify: false)
        defer { unwanted.sandbox.remove() }

        wanted.model.finish(enableLiveMode: false)
        unwanted.model.finish(enableLiveMode: false)
        try await Task.sleep(for: .milliseconds(50))

        #expect(wanted.prompt.calls == 1)
        #expect(unwanted.prompt.calls == 0)
    }

    @Test func thePromptIsShownAfterTheChoicesWereRecorded() async throws {
        let rig = try rig(notify: true, refresh: true)
        defer { rig.sandbox.remove() }
        var onboardingDoneWhenPromptOpened: Bool?
        let settings = rig.settings
        let model = OnboardingModel(
            settings: settings, liveGate: nil,
            requestNotificationPermission: { onboardingDoneWhenPromptOpened = settings.hasCompletedOnboarding })

        model.finish(enableLiveMode: true)

        #expect(await eventually { onboardingDoneWhenPromptOpened != nil })
        #expect(onboardingDoneWhenPromptOpened == true)
    }

    // MARK: - The Live gate

    @Test func theGateIsHeldOnlyWhenLiveModeAndNotificationsAreBothWanted() async throws {
        // Live mode and notifications: two system prompts could meet, so Live waits.
        let both = try rig(notify: true)
        defer { both.sandbox.remove() }
        both.model.finish(enableLiveMode: true)
        #expect(both.gate.holds.count == 1)
        #expect(await eventually { both.gate.releases == 1 })

        // Live mode without notifications: nothing else asks, nothing to hold.
        let liveOnly = try rig(notify: false)
        defer { liveOnly.sandbox.remove() }
        liveOnly.model.finish(enableLiveMode: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(liveOnly.gate.holds.isEmpty)
        #expect(liveOnly.gate.releases == 0)

        // Notifications without Live mode: there is no Keychain read to hold back.
        let notifyOnly = try rig(notify: true)
        defer { notifyOnly.sandbox.remove() }
        notifyOnly.model.finish(enableLiveMode: false)
        #expect(await eventually { notifyOnly.prompt.finished == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(notifyOnly.gate.holds.isEmpty)
        #expect(notifyOnly.gate.releases == 0)
    }

    @Test func theHoldEndsFifteenSecondsAfterTheClock() throws {
        let rig = try rig(notify: true)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        let hold = try #require(rig.gate.holds.first)
        #expect(hold.deadline == now.addingTimeInterval(15))
        #expect(OnboardingPlan.maxPromptWait == 15)
    }

    @Test func theHoldIsPlacedBeforeTheConsentIsRecorded() throws {
        let rig = try rig(notify: true)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        // So the engine can never see Live mode switched on without the hold.
        let hold = try #require(rig.gate.holds.first)
        #expect(!hold.liveModeAlreadyEnabled)
        #expect(!hold.onboardingAlreadyCompleted)
        #expect(rig.settings.liveModeEnabled)
    }

    @Test func theGateIsReleasedOnlyOnceThePromptWasAnswered() async throws {
        let rig = try rig(notify: true, answersAtOnce: false)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)
        try #require(await eventually { rig.prompt.calls == 1 })
        try await Task.sleep(for: .milliseconds(50))

        // The consent is already recorded, the prompt is still open, and Live requests still wait.
        #expect(rig.settings.liveModeEnabled)
        #expect(rig.gate.holds.count == 1)
        #expect(rig.gate.releases == 0)

        rig.prompt.answer()

        #expect(await eventually { rig.gate.releases == 1 })
        #expect(rig.prompt.finished == 1)
    }

    @Test func anUnansweredPromptDoesNotDropTheConsent() throws {
        let rig = try rig(notify: true, answersAtOnce: false)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        #expect(rig.settings.liveModeEnabled)
        #expect(rig.settings.hasCompletedOnboarding)
        #expect(rig.sandbox.makeSettings().liveModeEnabled)
        // Let the open prompt finish so no task is left waiting when the test ends.
        rig.prompt.answer()
    }

    @Test func withoutAGateTheChoicesAreStillRecordedAndThePromptStillShown() async throws {
        let rig = try rig(notify: true, withGate: false)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: true)

        #expect(rig.settings.liveModeEnabled)
        #expect(await eventually { rig.prompt.finished == 1 })
    }

    // MARK: - Every combination

    /// One way of leaving the window: the button (or the close button) and the two checkboxes.
    struct Combination: Sendable, CustomTestStringConvertible {
        var enableLive: Bool
        var closed: Bool
        var notify: Bool
        var refresh: Bool

        var testDescription: String {
            "live=\(enableLive) closed=\(closed) notify=\(notify) refresh=\(refresh)"
        }

        static let all: [Combination] = [true, false].flatMap { enableLive in
            [true, false].flatMap { closed in
                [true, false].flatMap { notify in
                    [true, false].map { refresh in
                        Combination(enableLive: enableLive, closed: closed, notify: notify, refresh: refresh)
                    }
                }
            }
        }
    }

    @Test(arguments: Combination.all)
    func everyCombinationRecordsExactlyWhatItShould(_ combination: Combination) async throws {
        let (enableLive, closed, notify, refresh) = (
            combination.enableLive, combination.closed, combination.notify, combination.refresh
        )
        let rig = try rig(notify: notify, refresh: refresh)
        defer { rig.sandbox.remove() }

        rig.model.finish(enableLiveMode: enableLive, closedWindow: closed)

        let live = enableLive && !closed
        #expect(rig.settings.liveModeEnabled == live)
        #expect(rig.settings.cliRefreshEnabled == (refresh && !closed))
        #expect(rig.settings.hasCompletedOnboarding)
        // A consent is saved with the version of the feature it was given for; no consent saves none.
        let saved = rig.sandbox.savedValues
        #expect(saved["liveModeConsentVersion"] as? Int == (live ? UsageAPI.consentVersion : nil))
        #expect(
            saved["cliRefreshConsentVersion"] as? Int == (refresh && !closed ? CLIRefreshCommand.consentVersion : nil))
        #expect(rig.settings.notificationThresholds.isEmpty == !notify)

        let holdsGate = live && notify
        #expect(rig.gate.holds.count == (holdsGate ? 1 : 0))
        #expect(await eventually { rig.prompt.finished == (notify ? 1 : 0) })
        #expect(await eventually { rig.gate.releases == (holdsGate ? 1 : 0) })
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.prompt.calls == (notify ? 1 : 0))
        #expect(rig.gate.releases == (holdsGate ? 1 : 0))
    }
}
