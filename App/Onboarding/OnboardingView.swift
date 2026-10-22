import AppKit
import Observation
import QuotaRingCore
import SwiftUI

/// Holds Live mode's first Keychain read while another system prompt may be open (implemented by ``AppModel``).
@MainActor protocol LiveRequestGate: AnyObject {
    func holdLiveRequests(until deadline: Date)
    func releaseLiveRequests()
}

/// The state of the first-run window and what finishing it does.
@MainActor @Observable
final class OnboardingModel {
    /// The "Notify me when I'm close to my limit" checkbox.
    var notifyNearLimit = true
    /// The "Keep numbers fresh with Claude Code" checkbox: on by default, as recommended for the Claude desktop app,
    /// whose usage Claude Code's cache otherwise never sees refreshed.
    var refreshWithClaudeCode = true
    private(set) var isFinished = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var liveGate: (any LiveRequestGate)?
    @ObservationIgnored private let requestNotificationPermission: @MainActor () async -> Void
    @ObservationIgnored private let now: () -> Date

    /// - Parameter requestNotificationPermission: shows the system notification prompt and returns when the user has
    ///   answered it; called only when the user left the notification checkbox on.
    init(
        settings: SettingsStore,
        liveGate: (any LiveRequestGate)?,
        requestNotificationPermission: @escaping @MainActor () async -> Void,
        now: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.liveGate = liveGate
        self.requestNotificationPermission = requestNotificationPermission
        self.now = now
    }

    /// Records the user's choices and completes onboarding, at once. Does nothing after the first call.
    ///
    /// Live mode turns on only here, through the explicit "Enable Live mode" button; every other way of leaving the
    /// window (the default button, Return, closing the window) leaves it off. Auto-refresh turns on only when one of the
    /// two buttons is pressed with its checkbox on; closing the window with its close button records it off. What is
    /// recorded is decided by ``OnboardingPlan``.
    ///
    /// - Parameter closedWindow: The window was closed with its close button rather than a button.
    ///
    /// Two system prompts must not appear at once. When the user wants both Live mode and notifications, the
    /// notification prompt comes first and Live mode's first Keychain read (which can raise macOS's Keychain prompt)
    /// waits until it was answered, or at most ``OnboardingPlan/maxPromptWait``. The consent itself is recorded right
    /// away, so a prompt that is never answered cannot drop it.
    func finish(enableLiveMode: Bool, closedWindow: Bool = false) {
        guard !isFinished else { return }
        isFinished = true

        let plan = OnboardingPlan(
            enableLiveMode: enableLiveMode,
            notifyNearLimit: notifyNearLimit,
            refreshWithClaudeCode: refreshWithClaudeCode,
            currentThresholds: settings.notificationThresholds,
            defaultThresholds: SettingsStore.defaultNotificationThresholds,
            closedWithoutChoosing: closedWindow)

        // The hold goes in before the consent, so the engine never sees Live mode on without it.
        let gate = plan.holdsLiveUntilPromptIsAnswered ? liveGate : nil
        gate?.holdLiveRequests(until: now().addingTimeInterval(OnboardingPlan.maxPromptWait))

        settings.notificationThresholds = plan.notificationThresholds
        settings.liveModeEnabled = plan.liveModeEnabled
        settings.cliRefreshEnabled = plan.cliRefreshEnabled
        // Last, so Live mode and auto-refresh (which need both) never see a half-finished state.
        settings.hasCompletedOnboarding = true

        guard plan.requestsNotificationPermission else { return }
        // The only place besides Settings that may show the system notification prompt.
        let request = requestNotificationPermission
        Task {
            await request()
            gate?.releaseLiveRequests()
        }
    }
}

/// The first-run window: what QuotaRing reads by default, what Live mode adds, and the choice between them.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    /// Called when a button is pressed; `true` for "Enable Live mode".
    let onChoose: (_ enableLiveMode: Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            // Scrolls on a short screen (or with longer translations), so the buttons below stay reachable.
            VStack(alignment: .leading, spacing: 18) {
                defaultModeCard
                liveModeCard
            }
            .scrollsBeyond(VisibleScreen.contentHeight(reserving: 330))

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(
                        "Keep numbers fresh with Claude Code (recommended if you use the Claude desktop app)",
                        isOn: $model.refreshWithClaudeCode)
                    Text(
                        "Runs the `claude` program now and then; it asks Anthropic for your usage with Claude Code's own login. No AI request, no usage spent, and QuotaRing never sees the login."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                }
                Toggle("Notify me when I'm close to my limit", isOn: $model.notifyNearLimit)
            }

            HStack {
                Spacer()
                Button("Enable Live mode") { onChoose(true) }
                Button("Use without Live mode") { onChoose(false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var defaultModeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By default, QuotaRing itself works entirely on this Mac:")
                .font(.headline)
            InfoRow(
                symbol: "doc.text",
                text: "It reads the usage numbers Claude Code already saves in its own cache file.")
            InfoRow(
                symbol: "info.circle",
                text:
                    "Only the `claude` command-line tool updates these numbers (a session or `/usage`); the Claude desktop app does not."
            )
            InfoRow(
                symbol: "text.alignleft",
                text:
                    "It counts tokens from Claude Code's local transcripts. The text of your conversations is not kept."
            )
            InfoRow(
                symbol: "lock.shield",
                text: "QuotaRing itself sends nothing: no account, no analytics, no network connections.")
        }
        .card()
    }

    /// The same wording as the consent sheet in Settings (the shared ``LiveModeDisclosure``), so the two cannot drift.
    private var liveModeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional — Live mode:")
                .font(.headline)
            Text("Live mode asks Anthropic for fresh numbers, even when Claude Code has not run for a while.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LiveModeDisclosure(compact: true)
            Text("You can turn Live mode and auto-refresh on or off at any time in Settings → Data.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to QuotaRing")
                    .font(.title.weight(.semibold))
                Text("See how much of your Claude session limit is left, right in the menu bar.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// A softly tinted rounded panel.
    fileprivate func card() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
