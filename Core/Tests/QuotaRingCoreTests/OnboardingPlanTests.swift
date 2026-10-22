import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct OnboardingPlanTests {
    private let defaults = [80, 95]

    private func plan(live: Bool, notify: Bool, current: [Int] = [80, 95]) -> OnboardingPlan {
        OnboardingPlan(
            enableLiveMode: live, notifyNearLimit: notify, currentThresholds: current, defaultThresholds: defaults)
    }

    @Test func liveAndNotificationsHoldTheFirstLiveRequestForThePrompt() {
        // Consent is recorded at once; only the first Keychain read waits, so two system prompts never overlap and an
        // unanswered notification prompt cannot drop the Live mode choice.
        #expect(
            plan(live: true, notify: true)
                == OnboardingPlan(
                    liveModeEnabled: true, notificationThresholds: [80, 95], requestsNotificationPermission: true,
                    holdsLiveUntilPromptIsAnswered: true))
        #expect(OnboardingPlan.maxPromptWait == 15)
    }

    @Test func liveWithoutNotificationsStartsAtOnce() {
        #expect(
            plan(live: true, notify: false)
                == OnboardingPlan(
                    liveModeEnabled: true, notificationThresholds: [], requestsNotificationPermission: false,
                    holdsLiveUntilPromptIsAnswered: false))
    }

    @Test func notificationsWithoutLiveNeverHold() {
        #expect(
            plan(live: false, notify: true)
                == OnboardingPlan(
                    liveModeEnabled: false, notificationThresholds: [80, 95], requestsNotificationPermission: true,
                    holdsLiveUntilPromptIsAnswered: false))
    }

    @Test func neitherLeavesEverythingOff() {
        #expect(
            plan(live: false, notify: false)
                == OnboardingPlan(
                    liveModeEnabled: false, notificationThresholds: [], requestsNotificationPermission: false,
                    holdsLiveUntilPromptIsAnswered: false))
    }

    @Test func notificationsKeepCustomThresholdsOrRestoreTheDefaults() {
        #expect(plan(live: false, notify: true, current: [50]).notificationThresholds == [50])
        #expect(plan(live: false, notify: true, current: []).notificationThresholds == [80, 95])
        #expect(plan(live: true, notify: false, current: [50]).notificationThresholds == [])
    }

    @Test func refreshWithClaudeCodeIsRecordedOnItsOwn() {
        // The checkbox is recorded as chosen, and it needs no system prompt, so it never holds Live mode back.
        for live in [false, true] {
            for notify in [false, true] {
                let on = OnboardingPlan(
                    enableLiveMode: live, notifyNearLimit: notify, refreshWithClaudeCode: true,
                    currentThresholds: [80, 95], defaultThresholds: defaults)
                let off = OnboardingPlan(
                    enableLiveMode: live, notifyNearLimit: notify, refreshWithClaudeCode: false,
                    currentThresholds: [80, 95], defaultThresholds: defaults)
                #expect(on.cliRefreshEnabled)
                #expect(!off.cliRefreshEnabled)
                #expect(on.holdsLiveUntilPromptIsAnswered == off.holdsLiveUntilPromptIsAnswered)
                #expect(on.liveModeEnabled == live)
            }
        }
        // Without the argument nothing is turned on.
        #expect(!plan(live: true, notify: true).cliRefreshEnabled)
    }

    @Test func closingTheWindowRecordsNeitherLiveModeNorAutoRefresh() {
        // The red close button is not a choice: whatever the checkbox shows, nothing that runs or reads is turned on.
        for notify in [false, true] {
            let closed = OnboardingPlan(
                enableLiveMode: false, notifyNearLimit: notify, refreshWithClaudeCode: true,
                currentThresholds: [80, 95], defaultThresholds: defaults, closedWithoutChoosing: true)
            #expect(!closed.liveModeEnabled)
            #expect(!closed.cliRefreshEnabled)
            #expect(!closed.holdsLiveUntilPromptIsAnswered)
        }
        // Even if a caller passed Live mode along with a close.
        let odd = OnboardingPlan(
            enableLiveMode: true, notifyNearLimit: true, refreshWithClaudeCode: true,
            currentThresholds: [80, 95], defaultThresholds: defaults, closedWithoutChoosing: true)
        #expect(!odd.liveModeEnabled)
        #expect(!odd.cliRefreshEnabled)
        #expect(!odd.holdsLiveUntilPromptIsAnswered)
    }

    @Test func eitherButtonRecordsTheCheckbox() {
        for live in [false, true] {
            let chosen = OnboardingPlan(
                enableLiveMode: live, notifyNearLimit: false, refreshWithClaudeCode: true,
                currentThresholds: [80, 95], defaultThresholds: defaults, closedWithoutChoosing: false)
            #expect(chosen.cliRefreshEnabled)
            #expect(chosen.liveModeEnabled == live)
        }
    }
}
