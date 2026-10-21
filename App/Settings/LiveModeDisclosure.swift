import SwiftUI

/// What Live mode reads, where it sends it, and what to expect. The single source of this wording: the full version is
/// shown in the consent sheet, the compact one in onboarding and the Data settings. Both carry the same four facts
/// (what is read, where it goes, the Keychain prompt, the undocumented endpoint and non-affiliation), so change them
/// together.
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
                to avoid repeated prompts.
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
                Reads Claude Code's login from your Keychain, or from Claude Code's credentials file if there is no \
                Keychain item. Read-only, again on each refresh, never stored.
                """)
        InfoRow(
            symbol: "network",
            text: """
                Sends it only to **api.anthropic.com** (/api/oauth/usage) to ask for your usage. Nothing else is \
                sent anywhere.
                """)
        InfoRow(
            symbol: "lock.shield",
            text: """
                macOS may ask to allow Keychain access: choose "Always Allow" to avoid repeated prompts.
                """)
        InfoRow(
            symbol: "exclamationmark.triangle",
            text: """
                Uses an undocumented endpoint that may stop working. QuotaRing is independent and not affiliated \
                with Anthropic.
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
