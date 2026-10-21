import AppKit
import Observation
import SwiftUI

/// The state of the first-run window and what finishing it does.
@MainActor @Observable
final class OnboardingModel {
    /// The "Notify me when I'm close to my limit" checkbox.
    var notifyNearLimit = true
    private(set) var isFinished = false

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let requestNotificationPermission: @MainActor () async -> Void

    /// - Parameter requestNotificationPermission: shows the system notification prompt and returns when the user has
    ///   answered it; called only when the user left the notification checkbox on.
    init(settings: SettingsStore, requestNotificationPermission: @escaping @MainActor () async -> Void) {
        self.settings = settings
        self.requestNotificationPermission = requestNotificationPermission
    }

    /// Records the user's choices and completes onboarding. Does nothing after the first call.
    ///
    /// Live mode turns on only here, through the explicit "Enable Live mode" button; every other way of leaving the
    /// window (the default button, Return, closing the window) leaves it off.
    ///
    /// Two system prompts must not appear at once. Live mode's first Keychain read can raise macOS's Keychain prompt, so
    /// when the user wants both, the notification prompt comes first and Live mode starts (consent recorded, onboarding
    /// completed) only after it was answered. Quitting in between leaves onboarding incomplete, so it simply shows
    /// again at the next launch.
    func finish(enableLiveMode: Bool) {
        guard !isFinished else { return }
        isFinished = true

        guard notifyNearLimit else {
            settings.notificationThresholds = []
            complete(enableLiveMode: enableLiveMode)
            return
        }
        if settings.notificationThresholds.isEmpty {
            settings.notificationThresholds = SettingsStore.defaultNotificationThresholds
        }
        // The only place besides Settings that may show the system notification prompt.
        let request = requestNotificationPermission
        if enableLiveMode {
            Task {
                await request()
                complete(enableLiveMode: true)
            }
        } else {
            complete(enableLiveMode: false)
            Task { await request() }
        }
    }

    private func complete(enableLiveMode: Bool) {
        settings.liveModeEnabled = enableLiveMode
        // Last, so Live mode (which needs both) never sees a half-finished state.
        settings.hasCompletedOnboarding = true
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
            .scrollsBeyond(VisibleScreen.contentHeight(reserving: 260))

            Toggle("Notify me when I'm close to my limit", isOn: $model.notifyNearLimit)

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
            Text("By default, QuotaRing works entirely on this Mac:")
                .font(.headline)
            InfoRow(
                symbol: "doc.text",
                text: "It reads the usage numbers Claude Code already saves in its own cache file.")
            InfoRow(
                symbol: "text.alignleft",
                text:
                    "It counts tokens from Claude Code's local transcripts. The text of your conversations is not kept."
            )
            InfoRow(
                symbol: "lock.shield",
                text: "Nothing leaves your Mac: no account, no analytics, no network connections.")
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
            Text("You can turn Live mode on or off at any time in Settings → Data.")
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
