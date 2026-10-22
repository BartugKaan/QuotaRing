import Foundation
import QuotaRingCore

/// Records what ``OnboardingModel`` asks of the Live gate, and what the settings looked like at that moment.
@MainActor
final class FakeLiveGate: LiveRequestGate {
    struct Hold {
        var deadline: Date
        /// Whether Live mode's consent was already saved when the hold was placed.
        var liveModeAlreadyEnabled: Bool
        var onboardingAlreadyCompleted: Bool
    }

    private let settings: SettingsStore
    private(set) var holds: [Hold] = []
    private(set) var releases = 0

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func holdLiveRequests(until deadline: Date) {
        holds.append(
            Hold(
                deadline: deadline, liveModeAlreadyEnabled: settings.liveModeEnabled,
                onboardingAlreadyCompleted: settings.hasCompletedOnboarding))
    }

    func releaseLiveRequests() {
        releases += 1
    }
}

/// Stands in for the system notification prompt. It counts its calls and, when `isOpen` is `false`, waits until the
/// test calls ``answer()``, like a user who has not yet decided.
@MainActor
final class FakePermissionPrompt {
    private(set) var calls = 0
    private(set) var finished = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let answersAtOnce: Bool

    init(answersAtOnce: Bool = true) {
        self.answersAtOnce = answersAtOnce
    }

    /// The closure handed to ``OnboardingModel``.
    var request: @MainActor () async -> Void {
        { [self] in
            calls += 1
            if !answersAtOnce {
                await withCheckedContinuation { waiting.append($0) }
            }
            finished += 1
        }
    }

    /// The user answers the prompt that is open.
    func answer() {
        let pending = waiting
        waiting = []
        for continuation in pending { continuation.resume() }
    }
}

/// Collects what ``AppModel`` hands to the notification service.
@MainActor
final class RecordingNotifier: UsageNotifier {
    private(set) var posts: [[ThresholdEvent]] = []

    var allEvents: [ThresholdEvent] { posts.flatMap { $0 } }

    func post(_ events: [ThresholdEvent], snapshot: UsageSnapshot) {
        posts.append(events)
    }
}
