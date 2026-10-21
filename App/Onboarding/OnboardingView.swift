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
    @ObservationIgnored private let requestNotificationPermission: @MainActor () -> Void

    /// - Parameter requestNotificationPermission: shows the system notification prompt; called only when the user
    ///   left the notification checkbox on.
    init(settings: SettingsStore, requestNotificationPermission: @escaping @MainActor () -> Void) {
        self.settings = settings
        self.requestNotificationPermission = requestNotificationPermission
    }

    /// Records the user's choices and completes onboarding. Does nothing after the first call.
    ///
    /// Live mode turns on only here, through the explicit "Enable Live mode" button; every other way of leaving the
    /// window (the default button, Return, closing the window) leaves it off.
    func finish(enableLiveMode: Bool) {
        guard !isFinished else { return }
        isFinished = true

        settings.liveModeEnabled = enableLiveMode
        if notifyNearLimit {
            if settings.notificationThresholds.isEmpty {
                settings.notificationThresholds = SettingsStore.defaultNotificationThresholds
            }
            // The only place besides Settings that may show the system permission prompt.
            requestNotificationPermission()
        } else {
            settings.notificationThresholds = []
        }
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

            VStack(alignment: .leading, spacing: 10) {
                Text("Optional — Live mode:")
                    .font(.headline)
                Text("Live mode asks Anthropic for fresh numbers, even when Claude Code has not run for a while.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                InfoRow(
                    symbol: "key",
                    text: """
                        It reads Claude Code's login from your Keychain: read-only, again on every refresh, and \
                        never stored by QuotaRing.
                        """)
                InfoRow(
                    symbol: "network",
                    text: "It sends that login only to **api.anthropic.com**, to ask for your usage. Nothing else.")
                InfoRow(
                    symbol: "exclamationmark.triangle",
                    text: """
                        macOS may ask to allow Keychain access; choose "Always Allow" to avoid repeated prompts. \
                        It uses an undocumented endpoint that may stop working.
                        """)
                Text("You can turn Live mode on or off at any time in Settings → Data.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .card()

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
