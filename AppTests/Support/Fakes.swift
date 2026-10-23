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

/// Stands in for the Keychain behind a Live request: answers every read with the answer it was given, counts the reads,
/// and can hold the next read until the test releases it, like a Keychain prompt that stays open.
final class FakeCredentialReader: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Result<OAuthCredential, CredentialError> = .failure(.notFound)
    private var gate: DispatchSemaphore?
    private var count = 0

    /// How many reads have started.
    var reads: Int { lock.withLock { count } }

    /// What the following reads answer.
    func answer(with result: Result<OAuthCredential, CredentialError>) {
        lock.withLock { current = result }
    }

    /// The reads that start from now on wait until ``releaseHeldRead()``, and answer what is set by then.
    func holdNextRead() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    /// Lets the held read go on, as if the user had answered the prompt, and holds no further read.
    func releaseHeldRead() {
        let held = lock.withLock { () -> DispatchSemaphore? in
            let held = gate
            gate = nil
            return held
        }
        held?.signal()
    }

    /// The closure handed to the engine.
    var reader: LiveCredentialReader {
        { [self] _ in
            let (held, answer) = lock.withLock { () -> (DispatchSemaphore?, Result<OAuthCredential, CredentialError>) in
                count += 1
                return (gate, current)
            }
            held?.wait()
            return lock.withLock { held == nil ? answer : current }
        }
    }
}

/// A transport that sends nothing and counts the attempts: a test that reaches it has found a Live request that goes out.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var requests: Int { lock.withLock { count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { count += 1 }
        throw URLError(.notConnectedToInternet)
    }
}

/// Stands in for the program that runs Claude Code's `/usage`: counts the runs and fails each of them at once, without
/// starting anything.
final class FakeCLIRunner: CLIRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// How many runs have been asked for.
    var runs: Int { lock.withLock { count } }

    private var binary: CLIBinaryState {
        CLIBinaryState(location: CLILocation(executable: nil, customPathProblem: .missing), versionCheck: nil)
    }

    func locate(_ settings: CLIRefresher.Settings) async -> CLIBinaryState {
        binary
    }

    func run(_ settings: CLIRefresher.Settings) async -> CLIRunReport {
        lock.withLock { count += 1 }
        return CLIRunReport(outcome: .failed(.launchFailed), binary: binary)
    }
}
