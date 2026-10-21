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
}
