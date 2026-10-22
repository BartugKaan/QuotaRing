import Foundation
import QuotaRingCore
import os

/// What the engine needs from the auto-refresh runner. ``CLIRefresher`` is the real one; tests stand in for it, because
/// a loop test must not start Claude Code.
protocol CLIRefreshing: Sendable {
    /// Where the tool is, from file metadata only.
    func locate(_ settings: CLIRefresher.Settings) async -> CLIBinaryState
    /// One refresh. Cancelling the calling task stops it.
    func run(_ settings: CLIRefresher.Settings) async -> CLIRunReport
}

extension CLIRefresher: CLIRefreshing {}

/// Runs Claude Code's own `/usage` so that it refreshes its usage cache, which QuotaRing then reads as usual
/// ("auto-refresh", spec §13). QuotaRing never sees a credential: Claude Code uses and renews its own login.
///
/// What is run is fixed in Core: the file is found and validated by ``ClaudeCLILocator``, checked with `--version` once
/// per file, and started by ``BoundedProcess`` with ``CLIRefreshCommand``'s argument array (no shell), a minimal
/// environment, `/dev/null` as input, a 30 s time limit and a 256 KB output limit. This type adds what only the app
/// knows: the user, the language, the working directory and the settings. It never logs what the tool printed, only
/// the outcome's name.
///
/// Everything runs off the main actor: the executor is an actor, and the process is watched by Dispatch.
final class CLIRefresher: Sendable {
    private let executor = CLIRefreshExecutor()

    /// What a run needs from the settings, captured on the main actor.
    struct Settings: Equatable, Sendable {
        var customCLIPath: URL?
        var customConfigDirectory: URL?
    }

    /// Where the tool is, from file metadata only (nothing is executed), with the remembered `--version` answer.
    func locate(_ settings: Settings) async -> CLIBinaryState {
        await executor.locate(Self.context(for: settings, workingDirectory: Self.workingDirectoryURL()))
    }

    /// One refresh. Cancelling the calling task stops the process.
    func run(_ settings: Settings) async -> CLIRunReport {
        let workingDirectory: URL
        do {
            workingDirectory = try Self.prepareWorkingDirectory()
        } catch {
            cliLog.error("Could not prepare the working folder for Claude Code")
            let binary = await locate(settings)
            return CLIRunReport(outcome: .failed(.launchFailed), binary: binary)
        }
        let report = await executor.run(Self.context(for: settings, workingDirectory: workingDirectory))
        cliLog.info("Claude Code refresh: \(report.outcome.logName, privacy: .public)")
        return report
    }

    // MARK: - Private

    private static func context(for settings: Settings, workingDirectory: URL) -> CLIRefreshContext {
        CLIRefreshContext(
            home: FileManager.default.homeDirectoryForCurrentUser,
            user: NSUserName(),
            lang: ProcessInfo.processInfo.environment["LANG"],
            customCLIPath: settings.customCLIPath,
            customConfigDirectory: settings.customConfigDirectory,
            workingDirectory: workingDirectory
        )
    }

    /// `~/Library/Application Support/QuotaRing/cli`: an empty folder of QuotaRing's own, so that no project's
    /// `.claude` settings or `CLAUDE.md` apply to the run.
    private static func workingDirectoryURL() -> URL {
        let support =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
        return
            support
            .appendingPathComponent("QuotaRing", isDirectory: true)
            .appendingPathComponent("cli", isDirectory: true)
    }

    /// Creates the working folder (and QuotaRing's folder above it) private to the user (0700), and checks that it is
    /// a real folder of the user's, not a symbolic link to somewhere else.
    private static func prepareWorkingDirectory() throws -> URL {
        let directory = workingDirectoryURL()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for folder in [directory.deletingLastPathComponent(), directory] {
            var info = stat()
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if info.st_mode & 0o777 != 0o700 {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
        }
        return directory
    }
}

private let cliLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "cli")

extension CLIRefreshOutcome {
    /// A short, non-sensitive name for logs.
    var logName: String {
        switch self {
        case .success: "success"
        case .modelCallDetected: "modelCallDetected"
        case .notLoggedIn: "notLoggedIn"
        case .failed(let reason): "failed(\(reason.rawValue))"
        }
    }
}

extension CLIRefreshStatus {
    /// A short, non-sensitive name for logs.
    var logName: String {
        switch self {
        case .off: "off"
        case .ok: "ok"
        case .running: "running"
        case .notFound: "notFound"
        case .unsupportedVersion: "unsupportedVersion"
        case .notLoggedIn: "notLoggedIn"
        case .failed(let reason): "failed(\(reason.rawValue))"
        case .disabledForSafety(let reason): "disabledForSafety(\(reason.rawValue))"
        }
    }
}
