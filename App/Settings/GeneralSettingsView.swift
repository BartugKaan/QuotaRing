import AppKit
import ServiceManagement
import SwiftUI

/// Launch at login, refresh interval and what the menu bar item shows.
struct GeneralSettingsView: View {
    @Bindable var settings: SettingsStore
    @State private var launchStatus: SMAppService.Status
    @State private var launchError: String?
    /// A fixed login item state for previews and screenshots; `nil` reads the real one from macOS.
    private let previewStatus: SMAppService.Status?

    init(settings: SettingsStore, previewStatus: SMAppService.Status? = nil, previewError: String? = nil) {
        self.settings = settings
        self.previewStatus = previewStatus
        _launchStatus = State(initialValue: previewStatus ?? LaunchAtLogin.status)
        _launchError = State(initialValue: previewError)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: launchAtLoginBinding)
                if launchStatus == .requiresApproval {
                    approvalNote
                }
                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Picker("Refresh interval", selection: $settings.refreshInterval) {
                    ForEach(SettingsStore.refreshOptions, id: \.self) { seconds in
                        Text(Self.intervalLabel(seconds)).tag(seconds)
                    }
                }
            } footer: {
                Text("Only affects Live mode; the Claude Code cache is checked every 30 s.")
            }

            Section("Menu bar") {
                Picker("Ring shows", selection: $settings.ringShowsRemaining) {
                    Text("Remaining").tag(true)
                    Text("Used").tag(false)
                }
                Toggle("Show percentage text", isOn: $settings.showPercentText)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if previewStatus == nil { refreshLaunchStatus() }
        }
        // The user may approve or remove the login item in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchStatus()
        }
    }

    // MARK: - Launch at login

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isRegistered(launchStatus) },
            set: { enabled in
                do {
                    try LaunchAtLogin.set(enabled)
                    launchError = nil
                } catch {
                    launchError =
                        enabled
                        ? String(
                            localized: "Could not turn on launch at login: \(error.localizedDescription)",
                            comment:
                                "Inline error under the Launch at login switch; the argument is the system's reason")
                        : String(
                            localized: "Could not turn off launch at login: \(error.localizedDescription)",
                            comment:
                                "Inline error under the Launch at login switch; the argument is the system's reason")
                }
                refreshLaunchStatus()
            }
        )
    }

    private var approvalNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS is waiting for your approval. Allow QuotaRing in System Settings → General → Login Items.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Items Settings…", action: LaunchAtLogin.openSystemSettings)
        }
    }

    private func refreshLaunchStatus() {
        launchStatus = LaunchAtLogin.status
    }

    // MARK: - Refresh interval

    /// For example "5 minutes".
    private static func intervalLabel(_ seconds: TimeInterval) -> String {
        Measurement(value: seconds / 60, unit: UnitDuration.minutes)
            .formatted(
                .measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0)))
            )
    }
}
