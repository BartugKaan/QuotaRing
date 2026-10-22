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
/// background run must never update Claude Code, which once left an npm install broken mid-update. It deliberately
/// does **not** set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`: verified on the owner's Mac, with it `/usage` answers
/// from the stale cache without asking Anthropic, which defeats the purpose.
public enum CLIRefreshCommand {
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
    /// for Claude Code to find system tools such as `security`.
    public static let standardPath = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"

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
    /// `PATH` and `DISABLE_AUTOUPDATER=1`, plus `CLAUDE_CONFIG_DIR` when a custom Claude config directory is set.
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
            "DISABLE_AUTOUPDATER": "1",
        ]
        if let customConfigDirectory {
            environment["CLAUDE_CONFIG_DIR"] =
                ClaudePaths(customConfigDirectory: customConfigDirectory)
                .configDirectory.path
        }
        return environment
    }
}
