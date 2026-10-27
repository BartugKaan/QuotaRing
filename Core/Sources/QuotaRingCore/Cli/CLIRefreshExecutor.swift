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
/// the same minimal environment as the run, so these checks cannot update Claude Code either. Only a definitive answer
/// (the check exited with status 0) is remembered, for the file's ``CLIFileIdentity`` (its resolved path and metadata),
/// so a replaced or updated file is checked again. A check that gave no answer (a failed exit, a timeout, a launch
/// failure, too much output) is not an answer, but the file rests for ``failedCheckRetryInterval`` before it is asked
/// again, so that a broken file early in the list does not cost up to 10 s before every refresh.
/// Something that is not Claude Code, or a Claude Code too old for the command's options, is skipped and the next
/// candidate is tried.
///
/// Right before every execution (each check, `/usage` and the login check) the file is inspected again and must still
/// be the one validated (same resolved file, same identity); otherwise it is not executed
/// (``CLIRefreshFailure/toolChanged``).
public actor CLIRefreshExecutor {
    /// Where to look for the tool; the standard places in the app, temporary files in tests.
    public typealias Candidates = @Sendable (_ home: URL, _ customPath: URL?) -> [URL]

    private let candidates: Candidates
    private let timeout: TimeInterval
    private let versionTimeout: TimeInterval
    private let killGrace: TimeInterval
    private var versionChecks: [CLIFileIdentity: CLIVersionCheck] = [:]
    /// Files whose `--help` lists the `auth` command (see ``ClaudeCLILocator/listsAuthCommand(helpOutput:)``).
    private var loginCheckTools: Set<CLIFileIdentity> = []
    /// Files whose last check gave no answer: why, and when.
    private var failedChecks: [CLIFileIdentity: (failure: CLIRefreshFailure, at: Date)] = [:]
    private let now: @Sendable () -> Date

    /// How long a file whose check gave no answer rests before it is checked again.
    public static let failedCheckRetryInterval: TimeInterval = 30 * 60

    /// - Parameter versionTimeout: The time limit of each check (`--version`, `--help`, the login check).
    public init(
        candidates: @escaping Candidates = { ClaudeCLILocator.candidates(home: $0, customPath: $1) },
        timeout: TimeInterval = CLIRefreshCommand.timeout,
        versionTimeout: TimeInterval = CLIRefreshCommand.versionTimeout,
        killGrace: TimeInterval = CLIRefreshCommand.killGrace,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.candidates = candidates
        self.timeout = timeout
        self.versionTimeout = versionTimeout
        self.killGrace = killGrace
        self.now = now
    }

    /// Why the last check of this file gave no answer, while the file is still resting (see
    /// ``failedCheckRetryInterval``).
    private func restingFailure(of identity: CLIFileIdentity) -> CLIRefreshFailure? {
        guard let failed = failedChecks[identity] else { return nil }
        let elapsed = now().timeIntervalSince(failed.at)
        guard elapsed >= 0, elapsed < Self.failedCheckRetryInterval else {
            failedChecks[identity] = nil
            return nil
        }
        return failed.failure
    }

    /// The tool a run would use, from file metadata and remembered checks only (nothing is executed): the first
    /// candidate known to be capable or not checked yet; otherwise the first known to be too old, then the first whose
    /// check gave no answer (still resting), then the first known not to be Claude Code.
    public func locate(_ context: CLIRefreshContext) -> CLIBinaryState {
        let search = search(context)
        var tooOld: CLIBinaryState?
        var resting: CLIBinaryState?
        var notClaudeCode: CLIBinaryState?
        for executable in search.executables {
            let check = versionChecks[executable.identity]
            let state = Self.state(executable, check, search)
            switch check {
            case nil:
                if restingFailure(of: executable.identity) == nil { return state }
                if resting == nil { resting = state }
            case .claudeCode:
                return state
            case .unsupported:
                if tooOld == nil { tooOld = state }
            case .notClaudeCode:
                if notClaudeCode == nil { notClaudeCode = state }
            }
        }
        return tooOld ?? resting ?? notClaudeCode ?? Self.state(nil, nil, search)
    }

    /// One refresh: find the first capable Claude Code (checking each candidate once per file), run `/usage` with it,
    /// read the result.
    ///
    /// When no candidate is capable, the outcome is, in this order: the first Claude Code that is too old
    /// (``CLIRefreshFailure/unsupportedVersion``), else the first check that gave no definitive answer (a failed exit,
    /// a timeout, a launch failure, a file that changed), else ``CLIRefreshFailure/notFound``. Files that are not Claude
    /// Code are skipped silently.
    public func run(_ context: CLIRefreshContext) async -> CLIRunReport {
        let search = search(context)
        // A file that changed (or is gone) has a new identity: whatever rest its old identity had is forgotten.
        let present = Set(search.executables.map(\.identity))
        failedChecks = failedChecks.filter { present.contains($0.key) }
        var firstTooOld: CLIRunReport?
        var firstUnanswered: CLIRunReport?
        var notClaudeCode: CLIBinaryState?
        for executable in search.executables {
            let environment = environment(for: executable, context: context)
            let check: CLIVersionCheck
            if let remembered = versionChecks[executable.identity] {
                check = remembered
            } else if let failure = restingFailure(of: executable.identity) {
                // Asked recently without an answer: not asked again yet, and reported as before.
                if firstUnanswered == nil {
                    firstUnanswered = CLIRunReport(
                        outcome: .failed(failure), binary: Self.state(executable, nil, search))
                }
                continue
            } else {
                switch await checkCapability(executable, environment: environment, context: context) {
                case .success(let result):
                    versionChecks[executable.identity] = result
                    failedChecks[executable.identity] = nil
                    check = result
                case .failure(.cancelled):
                    return CLIRunReport(outcome: .failed(.cancelled), binary: Self.state(executable, nil, search))
                case .failure(let failure):
                    // A file that changed under the check is a new file next time; anything else rests.
                    if failure != .toolChanged {
                        failedChecks[executable.identity] = (failure, now())
                    }
                    if firstUnanswered == nil {
                        firstUnanswered = CLIRunReport(
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
                if firstTooOld == nil {
                    firstTooOld = CLIRunReport(
                        outcome: .failed(.unsupportedVersion), binary: Self.state(executable, check, search))
                }
            case .notClaudeCode:
                if notClaudeCode == nil { notClaudeCode = Self.state(executable, check, search) }
            }
        }
        return firstTooOld ?? firstUnanswered
            ?? CLIRunReport(outcome: .failed(.notFound), binary: notClaudeCode ?? Self.state(nil, nil, search))
    }

    /// Whether the Claude Code that `binary` names (the tool of the last run) is signed in, asked with
    /// ``CLIRefreshCommand/loginStatusArguments`` in the run's environment and folder, within the time limit of a
    /// check. Only a tool this executor found to be a capable Claude Code whose `--help` lists the `auth` command is
    /// asked (another would read `auth` as the prompt of an interactive session), and only while it is still that very
    /// file.
    ///
    /// `nil` when there is no answer: the tool was not checked here or changed since, or the login check failed, ran
    /// too long, printed too much or answered without a yes or no (for example a Claude Code without `auth status`).
    public func isLoggedIn(_ context: CLIRefreshContext, binary: CLIBinaryState) async -> Bool? {
        guard let executable = binary.location.executable,
            case .claudeCode = versionChecks[executable.identity],
            loginCheckTools.contains(executable.identity),
            Self.isUnchanged(executable)
        else {
            return nil
        }
        let output = await BoundedProcess.run(
            executable: executable.executable,
            arguments: CLIRefreshCommand.loginStatusArguments,
            environment: environment(for: executable, context: context),
            currentDirectory: context.workingDirectory,
            timeout: versionTimeout,
            killGrace: killGrace,
            maxOutputBytes: CLIRefreshCommand.maxLoginStatusOutputBytes
        )
        guard case .exited(let status) = output.termination else { return nil }
        return CLIRefreshResult.loginState(stdout: output.stdout, exitCode: status)
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

    /// Whether the file `executable` was found at is, right now, still the very file that was validated: the same
    /// resolved path, the same identity, and still passing ``ClaudeCLILocator/inspect(_:)``.
    private static func isUnchanged(_ executable: CLIExecutable) -> Bool {
        guard case .success(let current) = ClaudeCLILocator.inspect(executable.path) else { return false }
        return current.executable == executable.executable && current.identity == executable.identity
    }

    private func runUsage(
        _ executable: CLIExecutable,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> CLIRefreshOutcome {
        guard Self.isUnchanged(executable) else { return .failed(.toolChanged) }
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
    /// ``ClaudeCLILocator/capability(versionOutput:helpOutput:)``. A success is a definitive answer, to be remembered;
    /// a failure is a check that gave none.
    private func checkCapability(
        _ executable: CLIExecutable,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> Result<CLIVersionCheck, CLIRefreshFailure> {
        let versionText: String
        switch await check(
            executable, arguments: CLIRefreshCommand.versionArguments,
            maxOutputBytes: CLIRefreshCommand.maxVersionOutputBytes, environment: environment, context: context)
        {
        case .success(let text):
            versionText = text
        case .failure(let failure):
            return .failure(failure)
        }
        guard ClaudeCLILocator.isClaudeCode(versionOutput: versionText) else { return .success(.notClaudeCode) }

        switch await check(
            executable, arguments: CLIRefreshCommand.helpArguments,
            maxOutputBytes: CLIRefreshCommand.maxHelpOutputBytes, environment: environment, context: context)
        {
        case .success(let helpText):
            if ClaudeCLILocator.listsAuthCommand(helpOutput: helpText) {
                loginCheckTools.insert(executable.identity)
            }
            return .success(ClaudeCLILocator.capability(versionOutput: versionText, helpOutput: helpText))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    /// Runs one check, after making sure the file is still the one validated. Its output when it exited with status 0;
    /// otherwise why it gave no answer: a failed exit, too much output, a timeout, a launch failure, or a changed file.
    private func check(
        _ executable: CLIExecutable,
        arguments: [String],
        maxOutputBytes: Int,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> Result<String, CLIRefreshFailure> {
        guard Self.isUnchanged(executable) else { return .failure(.toolChanged) }
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
        case .exited(0):
            return .success(String(decoding: output.stdout, as: UTF8.self))
        case .exited, .signaled:
            return .failure(.exitStatus)
        case .outputLimitExceeded:
            return .failure(.outputTooLarge)
        case .timedOut:
            return .failure(.timedOut)
        case .cancelled:
            return .failure(.cancelled)
        case .launchFailed:
            return .failure(.launchFailed)
        }
    }
}
