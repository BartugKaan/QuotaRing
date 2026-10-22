import Foundation

/// What `claude --version` said about a file.
public enum CLIVersionCheck: Equatable, Sendable {
    /// The output carries Claude Code's signature; `version` is its number when it could be read.
    case claudeCode(version: String?)
    /// The file is something else (or its `--version` misbehaved), so it is never run with `/usage`.
    case notClaudeCode
}

/// The command-line tool as last seen: where it is and, once checked, whether it is Claude Code.
public struct CLIBinaryState: Equatable, Sendable {
    public var location: CLILocation
    /// `nil` while the found file has not been checked (no run since it was found).
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

/// Finds Claude Code's tool, makes sure it is Claude Code, and runs ``CLIRefreshCommand`` with it.
///
/// The `--version` check runs once per file: its answer is remembered for the file's ``CLIFileIdentity``, so a
/// replaced or updated file is checked again. A timeout or launch failure is not remembered.
public actor CLIRefreshExecutor {
    /// Where to look for the tool; the standard places in the app, temporary files in tests.
    public typealias Candidates = @Sendable (_ home: URL, _ customPath: URL?) -> [URL]

    private let candidates: Candidates
    private let timeout: TimeInterval
    private let versionTimeout: TimeInterval
    private let killGrace: TimeInterval
    private var versionChecks: [CLIFileIdentity: CLIVersionCheck] = [:]

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

    /// Where the tool is, from file metadata only (nothing is executed), with the remembered `--version` answer.
    public func locate(_ context: CLIRefreshContext) -> CLIBinaryState {
        let location = ClaudeCLILocator.locate(
            candidates: candidates(context.home, context.customCLIPath), customPath: context.customCLIPath)
        let check = location.executable.flatMap { versionChecks[$0.identity] }
        return CLIBinaryState(location: location, versionCheck: check)
    }

    /// One refresh: locate, check `--version` (once per file), run `/usage`, read the result.
    public func run(_ context: CLIRefreshContext) async -> CLIRunReport {
        var binary = locate(context)
        guard let executable = binary.location.executable else {
            return CLIRunReport(outcome: .failed(.notFound), binary: binary)
        }
        let environment = CLIRefreshCommand.environment(
            home: context.home,
            user: context.user,
            lang: context.lang,
            binaryDirectory: executable.path.deletingLastPathComponent(),
            customConfigDirectory: context.customConfigDirectory
        )

        let check: CLIVersionCheck
        if let remembered = versionChecks[executable.identity] {
            check = remembered
        } else {
            switch await checkVersion(executable, environment: environment, context: context) {
            case .success(let result):
                versionChecks[executable.identity] = result
                check = result
            case .failure(let failure):
                return CLIRunReport(outcome: .failed(failure), binary: binary)
            }
        }
        binary.versionCheck = check
        guard case .claudeCode = check else {
            return CLIRunReport(outcome: .failed(.notClaudeCode), binary: binary)
        }

        let output = await BoundedProcess.run(
            executable: executable.executable,
            arguments: CLIRefreshCommand.arguments,
            environment: environment,
            currentDirectory: context.workingDirectory,
            timeout: timeout,
            killGrace: killGrace,
            maxOutputBytes: CLIRefreshCommand.maxOutputBytes
        )
        return CLIRunReport(outcome: Self.outcome(of: output), binary: binary)
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

    private func checkVersion(
        _ executable: CLIExecutable,
        environment: [String: String],
        context: CLIRefreshContext
    ) async -> Result<CLIVersionCheck, CLIRefreshFailure> {
        let output = await BoundedProcess.run(
            executable: executable.executable,
            arguments: CLIRefreshCommand.versionArguments,
            environment: environment,
            currentDirectory: context.workingDirectory,
            timeout: versionTimeout,
            killGrace: killGrace,
            maxOutputBytes: CLIRefreshCommand.maxVersionOutputBytes
        )
        switch output.termination {
        case .exited(let status):
            let text = String(decoding: output.stdout, as: UTF8.self)
            guard status == 0, ClaudeCLILocator.isClaudeCode(versionOutput: text) else {
                return .success(.notClaudeCode)
            }
            return .success(.claudeCode(version: ClaudeCLILocator.version(fromVersionOutput: text)))
        case .outputLimitExceeded:
            // Claude Code's answer is one short line.
            return .success(.notClaudeCode)
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
