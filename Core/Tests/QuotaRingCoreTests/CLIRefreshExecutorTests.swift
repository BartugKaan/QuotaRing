import Foundation
import Testing

@testable import QuotaRingCore

private func fixtureText(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

/// A fake `claude`: a shell script that answers `--version` and prints a canned result for anything else. It records
/// each call's arguments, environment and working directory next to itself, because its environment is minimal and
/// cannot carry paths in.
private struct FakeClaude {
    let scratch: CLIScratchDirectory
    let tool: URL

    var folder: URL { tool.deletingLastPathComponent() }
    var calls: [String] {
        (try? String(contentsOf: folder.appendingPathComponent("calls.log"), encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) } ?? []
    }

    init(
        version: String = "2.1.287 (Claude Code)",
        result: String,
        exitStatus: Int = 0,
        sleepBeforeResult: Int = 0,
        at relativePath: String = "native/claude"
    ) throws {
        scratch = try CLIScratchDirectory("QuotaRingCLIExecutorTests")
        let resultFile = scratch.url.appendingPathComponent("result.json")
        try Data(result.utf8).write(to: resultFile)
        let here = "$(dirname \"$0\")"
        tool = try scratch.file(
            relativePath,
            contents: """
                #!/bin/sh
                echo "$*" >> "\(here)/calls.log"
                if [ "$1" = "--version" ]; then
                  echo "\(version)"
                  exit 0
                fi
                /usr/bin/env > "\(here)/env.txt"
                pwd -P > "\(here)/pwd.txt"
                sleep \(sleepBeforeResult)
                cat "\(resultFile.path)"
                exit \(exitStatus)
                """)
    }

    func recordedEnvironment() throws -> [String: String] {
        let text = try String(contentsOf: folder.appendingPathComponent("env.txt"), encoding: .utf8)
        var environment: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            environment[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        for added in ["PWD", "SHLVL", "_"] {
            environment.removeValue(forKey: added)
        }
        return environment
    }

    func context(customCLIPath: URL? = nil, customConfigDirectory: URL? = nil) throws -> CLIRefreshContext {
        let workingDirectory = scratch.url.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        return CLIRefreshContext(
            home: scratch.url.appendingPathComponent("home", isDirectory: true), user: "test", lang: "en_US.UTF-8",
            customCLIPath: customCLIPath, customConfigDirectory: customConfigDirectory,
            workingDirectory: workingDirectory)
    }

    /// An executor that only ever finds files of this scratch directory.
    func executor(candidates: [URL]? = nil, timeout: TimeInterval = 30) -> CLIRefreshExecutor {
        let fixed = candidates ?? [tool]
        return CLIRefreshExecutor(
            candidates: { _, custom in (custom.map { [$0] } ?? []) + fixed },
            timeout: timeout, versionTimeout: 30, killGrace: 0.3)
    }
}

private let usageCall = "-p /usage --safe-mode --no-session-persistence --output-format json"

@Suite struct CLIRefreshExecutorTests {
    @Test func checksTheVersionOnceThenRunsUsage() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let executor = fake.executor()
        let context = try fake.context()

        let first = await executor.run(context)
        #expect(first.outcome == .success)
        #expect(first.binary.versionCheck == .claudeCode(version: "2.1.287"))
        #expect(first.binary.location.executable?.executable == fake.tool)

        let second = await executor.run(context)
        #expect(second.outcome == .success)
        #expect(fake.calls == ["--version", usageCall, usageCall])
        // Settings sees the remembered answer without running anything.
        #expect(await executor.locate(context).versionCheck == .claudeCode(version: "2.1.287"))
        #expect(fake.calls.count == 3)
    }

    @Test func runsWithTheMinimalEnvironmentInItsOwnFolder() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let context = try fake.context()

        _ = await fake.executor().run(context)
        #expect(
            try fake.recordedEnvironment() == [
                "HOME": context.home.path,
                "USER": "test",
                "LOGNAME": "test",
                "LANG": "en_US.UTF-8",
                "PATH": fake.folder.path + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
            ])
        let pwd = try String(contentsOf: fake.folder.appendingPathComponent("pwd.txt"), encoding: .utf8)
        #expect(pwd == context.workingDirectory.path + "\n")
    }

    @Test func passesACustomConfigDirectory() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let config = fake.scratch.url.appendingPathComponent("work-claude", isDirectory: true)

        _ = await fake.executor().run(try fake.context(customConfigDirectory: config))
        #expect(try fake.recordedEnvironment()["CLAUDE_CONFIG_DIR"] == config.path)
    }

    @Test func putsTheFolderOfALinkOnPathAndRunsItsTarget() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"), at: "lib/claude-code/claude")
        defer { fake.scratch.remove() }
        let link = try fake.scratch.symlink("bin/claude", to: fake.tool)

        let report = await fake.executor(candidates: [link]).run(try fake.context())
        #expect(report.outcome == .success)
        #expect(report.binary.location.executable?.path == link)
        #expect(report.binary.location.executable?.executable == fake.tool)
        let path = try #require(try fake.recordedEnvironment()["PATH"])
        #expect(path.hasPrefix(link.deletingLastPathComponent().path + ":"))
    }

    @Test func prefersTheChosenTool() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let other = try fake.scratch.file("other/claude", contents: "#!/bin/sh\nexit 9\n")

        let report = await fake.executor(candidates: [other]).run(try fake.context(customCLIPath: fake.tool))
        #expect(report.outcome == .success)
        #expect(report.binary.location.executable?.executable == fake.tool)
    }

    @Test func somethingElseIsNeverRunWithUsage() async throws {
        let fake = try FakeClaude(version: "1.0.0", result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let executor = fake.executor()
        let context = try fake.context()

        #expect(await executor.run(context).outcome == .failed(.notClaudeCode))
        let second = await executor.run(context)
        #expect(second.outcome == .failed(.notClaudeCode))
        #expect(second.binary.versionCheck == .notClaudeCode)
        // Checked once, and `/usage` never ran.
        #expect(fake.calls == ["--version"])
    }

    @Test func aReplacedFileIsCheckedAgain() async throws {
        let fake = try FakeClaude(version: "1.0.0", result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let executor = fake.executor()
        let context = try fake.context()
        #expect(await executor.run(context).outcome == .failed(.notClaudeCode))

        // An update replaces the file in place with Claude Code.
        let updated = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { updated.scratch.remove() }
        try FileManager.default.removeItem(at: fake.tool)
        try FileManager.default.copyItem(at: updated.tool, to: fake.tool)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: fake.tool.path)

        #expect(await executor.run(context).outcome == .success)
    }

    @Test func nothingFoundRunsNothing() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let missing = fake.scratch.url.appendingPathComponent("nowhere/claude")

        let report = await fake.executor(candidates: [missing]).run(try fake.context())
        #expect(report.outcome == .failed(.notFound))
        #expect(report.binary.location.executable == nil)
        #expect(fake.calls.isEmpty)
    }

    @Test func reportsAnUnusableChoice() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"))
        defer { fake.scratch.remove() }
        let chosen = try fake.scratch.file("chosen/claude", mode: 0o775)

        let state = await fake.executor().locate(try fake.context(customCLIPath: chosen))
        #expect(state.location.customPathProblem == .writableByOthers)
        #expect(state.location.executable?.executable == fake.tool)
        #expect(state.versionCheck == nil)
        #expect(fake.calls.isEmpty)
    }

    @Test func modelCallIsReported() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-model-call"))
        defer { fake.scratch.remove() }
        #expect(await fake.executor().run(try fake.context()).outcome == .modelCallDetected)
    }

    @Test func notLoggedInIsReported() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-not-logged-in"), exitStatus: 1)
        defer { fake.scratch.remove() }
        #expect(await fake.executor().run(try fake.context()).outcome == .notLoggedIn)
    }

    @Test func aFailedExitIsReported() async throws {
        let fake = try FakeClaude(result: "boom", exitStatus: 1)
        defer { fake.scratch.remove() }
        #expect(await fake.executor().run(try fake.context()).outcome == .failed(.exitStatus))
    }

    @Test func aHangingRunTimesOut() async throws {
        let fake = try FakeClaude(result: try fixtureText("cli-usage-success"), sleepBeforeResult: 30)
        defer { fake.scratch.remove() }
        let started = Date()
        #expect(await fake.executor(timeout: 0.5).run(try fake.context()).outcome == .failed(.timedOut))
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func terminationsMapToOutcomes() {
        #expect(
            CLIRefreshExecutor.outcome(of: ProcessOutput(termination: .signaled(9), stdout: Data()))
                == .failed(.exitStatus))
        #expect(
            CLIRefreshExecutor.outcome(of: ProcessOutput(termination: .outputLimitExceeded, stdout: Data()))
                == .failed(.outputTooLarge))
        #expect(
            CLIRefreshExecutor.outcome(of: ProcessOutput(termination: .cancelled, stdout: Data()))
                == .failed(.cancelled))
        #expect(
            CLIRefreshExecutor.outcome(of: ProcessOutput(termination: .launchFailed, stdout: Data()))
                == .failed(.launchFailed))
    }
}
