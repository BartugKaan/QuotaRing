import QuotaRingCore
import SwiftUI

/// What auto-refresh runs, how often, and what it does not do. The single source of this wording: the full version is
/// shown in the consent sheet, the compact one in the Data settings. Both carry the same facts (the exact command, when
/// it runs, Claude Code's own login, no model request and no usage spent, nothing saved), so change them together.
struct CLIRefreshDisclosure: View {
    var compact = false
    /// The refresh interval, to say how often in plain words.
    let refreshInterval: TimeInterval
    /// The tool that would run, for example `~/.local/bin/claude`; `nil` when none was found.
    var toolPath: String?

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
        VStack(alignment: .leading, spacing: 6) {
            InfoRow(
                symbol: "terminal",
                title: "What runs",
                text: "Claude Code's own `/usage` command, in the background, exactly like this:")
            CLICommandLine(toolPath: toolPath)
                .padding(.leading, 32)
        }
        InfoRow(
            symbol: "clock",
            title: "How often",
            text: """
                Only when the numbers shown are older than your refresh interval (now \
                \(GeneralSettingsView.intervalLabel(refreshInterval))), at most every 2 minutes, and not while your \
                Mac sleeps or is offline. The Refresh button runs it too, at most once a minute.
                """)
        InfoRow(
            symbol: "key",
            title: "Your login",
            text: """
                Claude Code uses and renews its own login. QuotaRing never reads, sees or stores your credentials.
                """)
        InfoRow(
            symbol: "checkmark.shield",
            title: "No AI request, no usage spent",
            text: """
                `/usage` only asks Anthropic for your usage numbers. If Claude Code ever answers it with a model \
                request instead, QuotaRing turns auto-refresh off by itself and tells you.
                """)
        InfoRow(
            symbol: "tray",
            title: "Nothing saved",
            text: """
                No session is saved, Claude Code does not update itself, and no plugins, hooks or MCP servers \
                start. It runs in an empty folder of QuotaRing's own.
                """)
    }

    @ViewBuilder
    private var compactRows: some View {
        InfoRow(
            symbol: "terminal",
            text: """
                Runs Claude Code's own `/usage` in the background when the numbers are older than the refresh \
                interval, at most every 2 minutes.
                """)
        InfoRow(
            symbol: "key",
            text: """
                Claude Code uses its own login; QuotaRing never sees your credentials. No AI request, no usage spent, \
                no session saved.
                """)
    }
}

/// The exact command line, monospaced and selectable, built from ``CLIRefreshCommand/arguments`` so it cannot drift
/// from what runs.
struct CLICommandLine: View {
    var toolPath: String?

    var body: some View {
        Text(verbatim: Self.text(toolPath: toolPath))
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// For example `claude -p "/usage" --safe-mode --no-session-persistence --output-format json`.
    static func text(toolPath: String?) -> String {
        let arguments = CLIRefreshCommand.arguments.map { argument in
            argument.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } ? argument : "\"\(argument)\""
        }
        return ([toolPath ?? "claude"] + arguments).joined(separator: " ")
    }
}

/// The confirmation the user must give before auto-refresh turns on from Settings.
struct CLIRefreshConsentSheet: View {
    let refreshInterval: TimeInterval
    var toolPath: String?
    let onEnable: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Turn on auto-refresh?")
                    .font(.title2.weight(.semibold))
                Text(
                    "QuotaRing will run Claude Code's command-line tool to keep its usage numbers fresh. Here is exactly what happens."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            CLIRefreshDisclosure(refreshInterval: refreshInterval, toolPath: toolPath)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                // Deliberately no default button: it turns on only by clicking this, never from a key press.
                Button("Turn on auto-refresh", action: onEnable)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

/// How to name the `claude` tool in the UI.
enum CLIToolName {
    /// "Claude app (2.1.308)" for a Claude Code build bundled with the Claude desktop app, whose path is long and says
    /// little; otherwise the path with `~` for the home folder.
    static func display(_ path: URL) -> String {
        if let version = ClaudeCLILocator.desktopAppVersion(of: path) {
            return String(
                localized: "Claude app (\(version))",
                comment: "The Claude Code build bundled with the Claude desktop app; the argument is its version")
        }
        return (path.path as NSString).abbreviatingWithTildeInPath
    }
}

/// User-facing texts about auto-refresh, shared by Settings and the popover.
enum CLIRefreshText {
    /// What a status means for the user; `nil` when there is nothing to say (off, or on and waiting for a first run).
    static func statusMessage(_ status: CLIRefreshStatus, now: Date) -> LocalizedStringKey? {
        switch status {
        case .off, .ok(lastRun: nil):
            return nil
        case .ok(let lastRun?):
            let age = QuotaFormat.age(of: lastRun, now: now, locale: .current)
            return "Auto-refresh last ran \(age)."
        case .running:
            return "Auto-refresh is running Claude Code…"
        case .notFound:
            return
                "Auto-refresh can't find Claude Code's command-line tool (`claude`). Install it, or choose it in Settings → Data."
        case .unsupportedVersion(let path?, let version?):
            let name = CLIToolName.display(URL(fileURLWithPath: path))
            return "Claude Code \(version) at \(name) is too old for auto-refresh — update it or choose another."
        case .unsupportedVersion(let path?, nil):
            let name = CLIToolName.display(URL(fileURLWithPath: path))
            return "Claude Code at \(name) is too old for auto-refresh — update it or choose another."
        case .unsupportedVersion(nil, _):
            return "The Claude Code found is too old for auto-refresh — update it or choose another."
        case .notLoggedIn:
            return "Auto-refresh: Claude Code is not signed in. Run `claude` once in Terminal and sign in."
        case .disabledForSafety:
            return
                "Auto-refresh turned itself off: Claude Code answered `/usage` with a model request, which would use your limits."
        case .failed(let reason):
            return failureMessage(reason)
        }
    }

    private static func failureMessage(_ reason: CLIRefreshFailure) -> LocalizedStringKey {
        switch reason {
        case .timedOut:
            "Auto-refresh: Claude Code took too long and was stopped. QuotaRing tries again later."
        case .launchFailed:
            "Auto-refresh: Claude Code could not be started. QuotaRing tries again later."
        case .outputTooLarge:
            "Auto-refresh: Claude Code printed far more than expected and was stopped. QuotaRing tries again later."
        case .exitStatus, .reportedError:
            "Auto-refresh: Claude Code reported an error. QuotaRing tries again later."
        case .unparsable, .unexpectedOutput:
            "Auto-refresh: Claude Code's answer was not in the expected format. QuotaRing tries again later."
        case .cacheNotUpdated:
            "Auto-refresh: Claude Code ran, but its usage numbers did not change. QuotaRing tries again later."
        case .notFound, .notClaudeCode, .unsupportedVersion, .cancelled:
            "Auto-refresh could not run Claude Code. QuotaRing tries again later."
        }
    }

    /// Why a chosen file cannot be used as Claude Code's tool.
    static func validationMessage(_ error: CLIValidationError) -> LocalizedStringKey {
        switch error {
        case .missing: "The chosen file no longer exists."
        case .notAFile: "The chosen item is not a file."
        case .notExecutable: "The chosen file is not a program that can be run."
        case .untrustedOwner: "The chosen file belongs to another user, so QuotaRing does not run it."
        case .writableByOthers: "Other users can change the chosen file, so QuotaRing does not run it."
        case .unreadable: "The chosen file can't be read."
        }
    }
}
