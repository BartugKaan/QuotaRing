import SwiftUI

/// What Live mode reads, where it sends it, and what to expect. The full version is shown in the consent sheet; the
/// compact one in the Data settings. Keep the two saying the same thing.
struct LiveModeDisclosure: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            if compact {
                compactRows
            } else {
                fullRows
            }
        }
    }

    @ViewBuilder
    private var fullRows: some View {
        InfoRow(
            symbol: "key",
            title: "What QuotaRing reads",
            text: """
                Claude Code's login (an access token) from your macOS Keychain, or from Claude Code's own \
                credentials file if there is no Keychain item. Read-only: QuotaRing reads it again on each \
                refresh and never stores it or changes it.
                """)
        InfoRow(
            symbol: "network",
            title: "Where it goes",
            text: """
                Only to **api.anthropic.com**: one request to /api/oauth/usage to ask for your current usage. \
                Nothing else is sent anywhere.
                """)
        InfoRow(
            symbol: "lock.shield",
            title: "Keychain prompt",
            text: """
                macOS may ask whether QuotaRing can use Claude Code's Keychain item. Choose "Always Allow" \
                so it does not ask again.
                """)
        InfoRow(
            symbol: "exclamationmark.triangle",
            title: "Good to know",
            text: """
                This uses an undocumented Anthropic endpoint that can change or stop working at any time. \
                QuotaRing is independent and not affiliated with Anthropic.
                """)
    }

    @ViewBuilder
    private var compactRows: some View {
        InfoRow(
            symbol: "key",
            text: """
                Reads Claude Code's login from your Keychain (or Claude Code's credentials file): read-only, again \
                on each refresh, never stored.
                """)
        InfoRow(
            symbol: "network",
            text: """
                Sends it only to **api.anthropic.com** (/api/oauth/usage) to ask for your usage. Nothing else is \
                sent anywhere.
                """)
        InfoRow(
            symbol: "exclamationmark.triangle",
            text: """
                Uses an undocumented endpoint, so it may stop working. macOS may ask for Keychain access: choose \
                "Always Allow".
                """)
    }
}

/// The confirmation the user must give before Live mode turns on from Settings.
struct LiveModeConsentSheet: View {
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Turn on Live mode?")
                    .font(.title2.weight(.semibold))
                Text("Live mode asks Anthropic for fresher numbers. Here is exactly what happens.")
                    .foregroundStyle(.secondary)
            }
            LiveModeDisclosure()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // Deliberately no default button: Live mode turns on only by clicking this, never from a key press.
                Button("Enable Live mode", action: onEnable)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
