import Foundation

/// What `claude --version` and `claude --help` said about a file.
public enum CLIVersionCheck: Equatable, Sendable {
    /// Claude Code that knows every option auto-refresh uses; `version` is its number when it could be read.
    case claudeCode(version: String?)
    /// Claude Code too old for auto-refresh: its `--help` lacks an option of ``CLIRefreshCommand/requiredFlags``.
    case unsupported(version: String?)
    /// The file is something else (or its `--version` misbehaved), so it is never run with `/usage`.
    case notClaudeCode
}

/// The command-line tool as last seen: the one used (or the one to tell the user about) and, once checked, what it is.
public struct CLIBinaryState: Equatable, Sendable {
    /// `executable` is the tool a run would use; when none is usable, the one that explains why (too old, or not
    /// Claude Code), or `nil` when nothing was found at all.
    public var location: CLILocation
    /// `nil` while that file has not been checked (no run since it was found).
    public var versionCheck: CLIVersionCheck?

    public init(location: CLILocation, versionCheck: CLIVersionCheck?) {
        self.location = location
        self.versionCheck = versionCheck
    }
}

/// The result of ``CLIRefreshExecutor/run(_:)``.
public struct CLIRunReport: Equatable, Sendable {
    public var outcome: CLIRefreshOutcome
    /// The tool that was used (or looked for), for Settings.
    public var binary: CLIBinaryState

    public init(outcome: CLIRefreshOutcome, binary: CLIBinaryState) {
        self.outcome = outcome
        self.binary = binary
    }
}

/// Everything a run depends on, captured on the main actor when it starts.
public struct CLIRefreshContext: Equatable, Sendable {
    public var home: URL
    public var user: String
    public var lang: String?
    /// The tool chosen in Settings, tried before the standard places.
    public var customCLIPath: URL?
    /// The Claude config directory chosen in Settings; passed on as `CLAUDE_CONFIG_DIR`.
    public var customConfigDirectory: URL?
    /// The tool's working directory: an empty folder of QuotaRing's own, so no project settings apply.
    public var workingDirectory: URL

    public init(
        home: URL,
        user: String,
        lang: String?,
        customCLIPath: URL?,
        customConfigDirectory: URL?,
        workingDirectory: URL
    ) {
        self.home = home
        self.user = user
        self.lang = lang
        self.customCLIPath = customCLIPath
        self.customConfigDirectory = customConfigDirectory
        self.workingDirectory = workingDirectory
    }
}

/// Finds a Claude Code that knows every option of the command, and runs ``CLIRefreshCommand`` with it.
///
/// Every usable candidate is tried in order. Each is asked `--version` and, only if it is Claude Code, `--help`, with
/// the same minimal environment as the run, so these checks cannot update Claude Code either. The answer is remembered
/// for the file's ``CLIFileIdentity`` (its resolved path and metadata), so a replaced or updated file is checked again;
/// a timeout or launch failure is not remembered. Something that is not Claude Code, or a Claude Code too old for the
/// command's options, is skipped and the next candidate is tried.
public actor CLIRefreshExecutor {
    /// Where to look for the tool; the standard places in the app, temporary files in tests.
    public typealias Candidates = @Sendable (_ home: URL, _ customPath: URL?) -> [URL]

    private let candidates: Candidates
    private let timeout: TimeInterval
    private let versionTimeout: TimeInterval
    private let killGrace: TimeInterval
    private var versionChecks: [CLIFileIdentity: CLIVersionCheck] = [:]

    /// - Parameter versionTimeout: The time limit of each check (`--version`, `--help`).
    public init(
        candidates: @escaping Candidates = { ClaudeCLILocator.candidates(home: $0, customPath: $1) },
        timeout: TimeInterval = CLIRefreshCommand.timeout,
        versionTimeout: TimeInterval = CLIRefreshCommand.versionTimeout,
        killGrace: TimeInterval = CLIRefreshCommand.killGrace
    ) {
        self.candidates = candidates
        self.timeout = timeout
        self.versionTimeout = versionTimeout
        self.killGrace = killGrace
    }

    /// The tool a run would use, from file metadata and remembered checks only (nothing is executed): the first
    /// candidate known to be capable or not checked yet; otherwise the first known to be too old, then the first known
    /// not to be Claude Code.
    public func locate(_ context: CLIRefreshContext) -> CLIBinaryState {
        let search = search(context)
        var tooOld: CLIBinaryState?
        var notClaudeCode: CLIBinaryState?
        for executable in search.executables {
            let check = versionChecks[executable.identity]
            let state = Self.state(executable, check, search)
            switch check {
            case nil, .claudeCode:
                return state
            case .unsupported:
                if tooOld == nil { tooOld = state }
            case .notClaudeCode:
                if notClaudeCode == nil { notClaudeCode = state }
            }
        }
        return tooOld ?? notClaudeCode ?? Self.state(nil, nil, search)
    }

    /// One refresh: find the first capable Claude Code (checking each candidate once per file), run `/usage` with it,
    /// read the result.
    ///
    /// When no candidate is capable, the outcome describes the first problem in candidate order: a check that could not
    /// finish (a timeout or launch failure) or a Claude Code that is too old
    /// (``CLIRefreshFailure/unsupportedVersion``). Files that are not Claude Code are skipped silently; with nothing
    /// else, the outcome is ``CLIRefreshFailure/notFound``.
    public func run(_ context: CLIRefreshContext) async -> CLIRunReport {
        let search = search(context)
        var firstProblem: CLIRunReport?
        var notClaudeCode: CLIBinaryState?
        for executable in search.executables {
            let environment = environment(for: executable, context: context)
            let check: CLIVersionCheck
            if let remembered = versionChecks[executable.identity] {
                check = remembered
            } else {
                switch await checkCapability(executable, environment: environment, context: context) {
                case .success(let result):
                    versionChecks[executable.identity] = result
                    check = result
                case .failure(.cancelled):
                    return CLIRunReport(outcome: .failed(.cancelled), binary: Self.state(executable, nil, search))
                case .failure(let failure):
                    if firstProblem == nil {
                        firstProblem = CLIRunReport(
                            outcome: .failed(failure), binary: Self.state(executable, nil, search))
                    }
                    continue
                }
            }
            switch check {
            case .claudeCode:
                let outcome = await runUsage(executable, environment: environment, context: context)
                return CLIRunReport(outcome: outcome, binary: Self.state(executable, check, search))
            case .unsupported:
                if firstProblem == nil {
                    firstProblem = CLIRunReport(
                        outcome: .failed(.unsupportedVersion), binary: Self.state(executable, check, search))
                }
            case .notClaudeCode:
                if notClaudeCode == nil { notClaudeCode = Self.state(executable, check, search) }
            }
        }
        return firstProblem
            ?? CLIRunReport(outcome: .failed(.notFound), binary: notClaudeCode ?? Self.state(nil, nil, search))
    }

    /// The outcome of a `/usage` run.
    static func outcome(of output: ProcessOutput) -> CLIRefreshOutcome {
        switch output.termination {
        case .exited(let status):
            return CLIRefreshResult.parse(stdout: output.stdout, exitCode: status)
        case .signaled:
            return .failed(.exitStatus)
        case .timedOut:
            return .failed(.timedOut)
        case .outputLimitExceeded:
            return .failed(.outputTooLarge)
        case .cancelled:
            return .failed(.cancelled)
        case .launchFailed:
            return .failed(.launchFailed)
        }
    }

    // MARK: - Private

    private func search(_ context: CLIRefreshContext) -> CLISearch {
        ClaudeCLILocator.search(
            candidates: candidates(context.home, context.customCLIPath), customPath: context.customCLIPath)
    }

    private static func state(
        _ executable: CLIExecutable?,
        _ check: CLIVersionCheck?,
        _ search: CLISearch
    ) -> CLIBinaryState {
        CLIBinaryState(
            location: CLILocation(executable: executable, customPathProblem: search.customPathProblem),
            versionCheck: check)
    }

    private func environment(for executable: CLIExecutable, context: CLIRefreshContext) -> [String: String] {
        CLIRefreshCommand.environment(
            home: context.home,
            user: context.user,
            lang: context.lang,
            binaryDirectory: executable.path.deletingLastPathComponent(),
            customConfigDirectory: context.customConfigDirectory
        )
    }

    private func runUsage(
        _ executable: CLIExecutable,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> CLIRefreshOutcome {
        let output = await BoundedProcess.run(
            executable: executable.executable,
            arguments: CLIRefreshCommand.arguments,
            environment: environment,
            currentDirectory: context.workingDirectory,
            timeout: timeout,
            killGrace: killGrace,
            maxOutputBytes: CLIRefreshCommand.maxOutputBytes
        )
        return Self.outcome(of: output)
    }

    /// `--version`, then, only for Claude Code, `--help`; see
    /// ``ClaudeCLILocator/capability(versionOutput:helpOutput:)``.
    private func checkCapability(
        _ executable: CLIExecutable,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> Result<CLIVersionCheck, CLIRefreshFailure> {
        let version = await check(
            executable, arguments: CLIRefreshCommand.versionArguments,
            maxOutputBytes: CLIRefreshCommand.maxVersionOutputBytes, environment: environment, context: context)
        let versionText: String
        switch version {
        case .success(let text?):
            versionText = text
        case .success(nil):
            return .success(.notClaudeCode)
        case .failure(let failure):
            return .failure(failure)
        }
        guard ClaudeCLILocator.isClaudeCode(versionOutput: versionText) else { return .success(.notClaudeCode) }

        let help = await check(
            executable, arguments: CLIRefreshCommand.helpArguments,
            maxOutputBytes: CLIRefreshCommand.maxHelpOutputBytes, environment: environment, context: context)
        switch help {
        case .success(let text):
            // A `--help` that fails or prints too much proves nothing: it counts as lacking the options.
            return .success(ClaudeCLILocator.capability(versionOutput: versionText, helpOutput: text ?? ""))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Runs one check. Its text when it exited with status 0; `nil` when it exited otherwise or printed too much (an
    /// answer, just not a useful one); a failure when it could not finish.
    private func check(
        _ executable: CLIExecutable,
        arguments: [String],
        maxOutputBytes: Int,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> Result<String?, CLIRefreshFailure> {
        let output = await BoundedProcess.run(
            executable: executable.executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: context.workingDirectory,
            timeout: versionTimeout,
            killGrace: killGrace,
            maxOutputBytes: maxOutputBytes
        )
        switch output.termination {
        case .exited(let status):
            return .success(status == 0 ? String(decoding: output.stdout, as: UTF8.self) : nil)
        case .outputLimitExceeded:
            return .success(nil)
        case .signaled:
            return .failure(.exitStatus)
        case .timedOut:
            return .failure(.timedOut)
        case .cancelled:
            return .failure(.cancelled)
        case .launchFailed:
            return .failure(.launchFailed)
        }
    }
}
