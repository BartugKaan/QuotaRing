import Foundation

/// The one command QuotaRing runs to make Claude Code refresh its usage cache, and the environment it runs in.
///
/// `claude -p "/usage" --safe-mode --no-session-persistence --output-format json` runs Claude Code's own `/usage`
/// command without a terminal. Verified with Claude Code 2.1.287: it makes no model request (`num_turns` 0,
/// `total_cost_usd` 0), saves no session, starts no plugins, hooks or MCP servers, and rewrites
/// `cachedUsageUtilization` in `~/.claude.json`, which QuotaRing then reads as usual. Claude Code uses and renews its
/// own login for it; QuotaRing never sees a credential.
///
/// Everything is fixed: the arguments are a constant array passed without a shell, and the environment is built from
/// scratch instead of inheriting QuotaRing's. It turns off Claude Code's auto-updater (`DISABLE_AUTOUPDATER=1`): a
/// background run must never update Claude Code, which once left an npm install broken mid-update. It also asks Claude
/// Code not to send telemetry or error reports (`DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`; whether it does is
/// up to Claude Code. Verified with 2.1.308: the cache still refreshes, with no turns and no cost). It deliberately
/// does **not** set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`: verified on the owner's Mac, with it `/usage` answers
/// from the stale cache without asking Anthropic, which defeats the purpose.
public enum CLIRefreshCommand {
    /// The version of what the user agrees to when turning on auto-refresh. The app records it with the consent, and a
    /// consent recorded for another version does not count, so the user is asked again.
    ///
    /// Bump it whenever what auto-refresh runs changes in a way the user agreed to: the command (``arguments``, or the
    /// arguments of the checks), the environment (``environment(home:user:lang:binaryDirectory:customConfigDirectory:)``,
    /// including ``standardPath`` and ``switchedOffFeatures``), which programs may be run, or the data it reads.
    public static let consentVersion = 1

    /// The arguments, exactly. `-p "/usage"` runs the slash command in print mode; `--safe-mode` starts no plugins,
    /// hooks or MCP servers; `--no-session-persistence` saves no transcript; `--output-format json` prints one result
    /// object that ``CLIRefreshResult/parse(stdout:exitCode:)`` checks.
    public static let arguments = [
        "-p", "/usage", "--safe-mode", "--no-session-persistence", "--output-format", "json",
    ]

    /// The arguments of the check that a file is Claude Code (see ``ClaudeCLILocator/isClaudeCode(versionOutput:)``).
    public static let versionArguments = ["--version"]

    /// The arguments of the check that this Claude Code knows ``requiredFlags``
    /// (see ``ClaudeCLILocator/capability(versionOutput:helpOutput:)``).
    public static let helpArguments = ["--help"]

    /// The options of ``arguments`` that older Claude Code versions lack. Without them a run could start plugins, hooks
    /// or MCP servers, or save a session, so a version whose `--help` does not list both is never run with `/usage`.
    public static let requiredFlags = ["--safe-mode", "--no-session-persistence"]

    /// The folders after the tool's own on its `PATH`: enough for a `#!/usr/bin/env node` launcher to find Node and
    /// for Claude Code to find system tools such as `security`. The system folders come first, so a file in a
    /// package-manager folder (which on a shared Mac may belong to another account) cannot shadow a system tool.
    ///
    /// The interpreter of a script-based install (for example `node` for a `#!/usr/bin/env node` launcher) is looked
    /// up on this `PATH` and is not checked the way the tool itself is (owner, permission bits); see SECURITY.md.
    public static let standardPath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

    /// The variables that turn Claude Code's auto-updater off and ask it not to send telemetry or error reports, in the
    /// order shown to the user. Part of every ``environment(home:user:lang:binaryDirectory:customConfigDirectory:)``.
    public static let switchedOffFeatures: [(name: String, value: String)] = [
        ("DISABLE_AUTOUPDATER", "1"), ("DISABLE_TELEMETRY", "1"), ("DISABLE_ERROR_REPORTING", "1"),
    ]

    /// `LANG` when QuotaRing itself has none (apps started by launchd usually do not).
    public static let defaultLanguage = "en_US.UTF-8"

    /// How long one refresh may run before it is stopped (verified runs take about 2 s).
    public static let timeout: TimeInterval = 30
    /// How long the `--version` check may run.
    public static let versionTimeout: TimeInterval = 10
    /// After asking a process to stop, how long to wait before killing it.
    public static let killGrace: TimeInterval = 2
    /// Output beyond this many bytes stops the run; a `/usage` result is about 1 KB.
    public static let maxOutputBytes = 262_144
    /// Output limit of the `--version` check.
    public static let maxVersionOutputBytes = 4_096
    /// Output limit of the `--help` check.
    public static let maxHelpOutputBytes = 262_144

    /// The complete environment of the tool, for `/usage` and for the checks alike: `HOME`, `USER`, `LOGNAME`, `LANG`,
    /// `PATH`, `DISABLE_AUTOUPDATER=1`, `DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1`, plus `CLAUDE_CONFIG_DIR`
    /// when a custom Claude config directory is set.
    /// Nothing is inherited from QuotaRing's own environment.
    ///
    /// - Parameters:
    ///   - lang: QuotaRing's `LANG`; ``defaultLanguage`` when `nil` or empty.
    ///   - binaryDirectory: The folder of the tool as found (``CLIExecutable/path``), first on `PATH`.
    ///   - customConfigDirectory: The Claude config directory chosen in Settings, or `nil` for the default.
    public static func environment(
        home: URL,
        user: String,
        lang: String?,
        binaryDirectory: URL,
        customConfigDirectory: URL?
    ) -> [String: String] {
        var environment = [
            "HOME": ClaudeCLILocator.standardizedPath(home.path),
            "USER": user,
            "LOGNAME": user,
            "LANG": lang.flatMap { $0.isEmpty ? nil : $0 } ?? defaultLanguage,
            "PATH": ClaudeCLILocator.standardizedPath(binaryDirectory.path) + ":" + standardPath,
        ]
        for feature in switchedOffFeatures {
            environment[feature.name] = feature.value
        }
        if let customConfigDirectory {
            environment["CLAUDE_CONFIG_DIR"] =
                ClaudePaths(customConfigDirectory: customConfigDirectory)
                .configDirectory.path
        }
        return environment
    }
}
