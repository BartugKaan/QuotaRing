import Foundation

/// What finishing the first-run window does, decided from the user's choices.
///
/// Live mode's consent is recorded and onboarding completes right away, whatever happens to the notification prompt:
/// a prompt the user never answers must not silently drop the "Enable Live mode" choice. Two system prompts must not
/// appear at once, though, and Live mode's first Keychain read can raise macOS's Keychain prompt. So when the user wants
/// both, the first Live request waits until the notification prompt was answered, or at most ``maxPromptWait``.
public struct OnboardingPlan: Equatable, Sendable {
    /// The longest the first Live request waits for the notification prompt to be answered.
    public static let maxPromptWait: TimeInterval = 15

    /// The Live mode consent to record.
    public var liveModeEnabled: Bool
    /// The consent to refresh through Claude Code ("auto-refresh") to record.
    public var cliRefreshEnabled: Bool
    /// The notification thresholds to store.
    public var notificationThresholds: [Int]
    /// Whether to show the system notification prompt.
    public var requestsNotificationPermission: Bool
    /// Whether the first Live request must wait for the notification prompt (at most ``maxPromptWait``).
    public var holdsLiveUntilPromptIsAnswered: Bool

    public init(
        liveModeEnabled: Bool,
        cliRefreshEnabled: Bool = false,
        notificationThresholds: [Int],
        requestsNotificationPermission: Bool,
        holdsLiveUntilPromptIsAnswered: Bool
    ) {
        self.liveModeEnabled = liveModeEnabled
        self.cliRefreshEnabled = cliRefreshEnabled
        self.notificationThresholds = notificationThresholds
        self.requestsNotificationPermission = requestsNotificationPermission
        self.holdsLiveUntilPromptIsAnswered = holdsLiveUntilPromptIsAnswered
    }

    /// - Parameters:
    ///   - enableLiveMode: `true` only for the explicit "Enable Live mode" button.
    ///   - notifyNearLimit: The "Notify me when I'm close to my limit" checkbox.
    ///   - refreshWithClaudeCode: The "Keep numbers fresh with Claude Code" checkbox. It needs no system prompt, so it
    ///     never holds anything back.
    ///   - currentThresholds: The thresholds stored now; kept when notifications are wanted and some are set.
    ///   - defaultThresholds: Used when notifications are wanted and none are set.
    public init(
        enableLiveMode: Bool,
        notifyNearLimit: Bool,
        refreshWithClaudeCode: Bool = false,
        currentThresholds: [Int],
        defaultThresholds: [Int]
    ) {
        liveModeEnabled = enableLiveMode
        cliRefreshEnabled = refreshWithClaudeCode
        if notifyNearLimit {
            notificationThresholds = currentThresholds.isEmpty ? defaultThresholds : currentThresholds
        } else {
            notificationThresholds = []
        }
        requestsNotificationPermission = notifyNearLimit
        holdsLiveUntilPromptIsAnswered = enableLiveMode && notifyNearLimit
    }
}
