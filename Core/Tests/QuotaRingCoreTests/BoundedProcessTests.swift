import Darwin
import Foundation
import Testing

@testable import QuotaRingCore

/// Runs fake tools: small `/bin/sh` scripts in a scratch directory. No real `claude` is ever run.
@Suite struct BoundedProcessTests {
    private let environment = ["HOME": "/tmp", "USER": "test", "LOGNAME": "test", "LANG": "C", "PATH": "/usr/bin:/bin"]

    private func run(
        _ script: URL,
        in directory: URL,
        arguments: [String] = [],
        timeout: TimeInterval = 30,
        killGrace: TimeInterval = 0.5,
        maxOutputBytes: Int = 65_536,
        endOfOutputGrace: TimeInterval = 0.5
    ) async -> ProcessOutput {
        await BoundedProcess.run(
            executable: script, arguments: arguments, environment: environment, currentDirectory: directory,
            timeout: timeout, killGrace: killGrace, maxOutputBytes: maxOutputBytes, endOfOutputGrace: endOfOutputGrace)
    }

    @Test func collectsOutputAndExitStatus() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\nprintf '%s|%s' \"$1\" \"$2\"\nexit 0\n")

        let output = await run(script, in: scratch.url, arguments: ["-p", "/usage"])
        #expect(output == ProcessOutput(termination: .exited(0), stdout: Data("-p|/usage".utf8)))
    }

    @Test func argumentsAreNotInterpretedByAShell() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\nprintf '%s' \"$1\"\n")

        let output = await run(script, in: scratch.url, arguments: ["$(touch pwned); `id`"])
        #expect(output.stdout == Data("$(touch pwned); `id`".utf8))
        #expect(!FileManager.default.fileExists(atPath: scratch.url.appendingPathComponent("pwned").path))
    }

    @Test func reportsANonZeroExit() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\necho partial\nexit 3\n")

        let output = await run(script, in: scratch.url)
        #expect(output == ProcessOutput(termination: .exited(3), stdout: Data("partial\n".utf8)))
    }

    @Test func environmentIsExactlyTheOneGiven() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\n/usr/bin/env\n")

        let output = await run(script, in: scratch.url)
        var seen: [String: String] = [:]
        for line in String(decoding: output.stdout, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            seen[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        // `sh` itself adds PWD, SHLVL and `_`; everything else must be what was passed, and nothing inherited.
        for added in ["PWD", "SHLVL", "_"] {
            seen.removeValue(forKey: added)
        }
        #expect(seen == environment)
    }

    @Test func runsInTheGivenDirectoryWithStdinFromDevNull() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file(
            "tool",
            contents: """
                #!/bin/sh
                pwd -P
                if [ "$(stat -L -f %Hr,%Lr /dev/fd/0)" = "$(stat -f %Hr,%Lr /dev/null)" ]; then echo null; fi
                cat
                echo done
                """)

        let output = await run(script, in: scratch.url, timeout: 30)
        #expect(output.termination == .exited(0))
        #expect(String(decoding: output.stdout, as: UTF8.self) == scratch.url.path + "\nnull\ndone\n")
    }

    @Test func timeoutStopsTheProcess() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\necho started\nexec sleep 30\n")

        let started = Date()
        let output = await run(script, in: scratch.url, timeout: 0.3)
        #expect(output == ProcessOutput(termination: .timedOut, stdout: Data()))
        #expect(Date().timeIntervalSince(started) < 15)
    }

    /// Starts `script` in a task and cancels it once `marker` exists, so the script has reached a known point however
    /// slowly the machine launches it.
    private func runUntil(_ marker: URL, _ script: URL, in directory: URL) async throws -> (ProcessOutput, TimeInterval)
    {
        let environment = self.environment
        let task = Task {
            await BoundedProcess.run(
                executable: script, arguments: [], environment: environment, currentDirectory: directory,
                timeout: 60, killGrace: 0.3, maxOutputBytes: 1_000)
        }
        for _ in 0..<600 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let cancelled = Date()
        task.cancel()
        let output = await task.value
        return (output, Date().timeIntervalSince(cancelled))
    }

    @Test func aProcessIgnoringTerminateIsKilled() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let marker = scratch.url.appendingPathComponent("ready")
        let script = try scratch.file(
            "tool", contents: "#!/bin/sh\ntrap '' TERM\ntouch \"\(marker.path)\"\nsleep 30\nsleep 30\n")

        let (output, stopping) = try await runUntil(marker, script, in: scratch.url)
        #expect(output.termination == .cancelled)
        // Killed after the 0.3 s grace, far sooner than the script's minute.
        #expect(stopping < 15)
    }

    @Test func helpersOfAStoppedProcessAreStoppedToo() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let pidFile = scratch.url.appendingPathComponent("helper.pid")
        let script = try scratch.file(
            "tool",
            contents:
                "#!/bin/sh\nsleep 30 &\necho $! > \"\(pidFile.path).tmp\"\nmv \"\(pidFile.path).tmp\" \"\(pidFile.path)\"\nwait\n"
        )

        let (output, _) = try await runUntil(pidFile, script, in: scratch.url)
        #expect(output.termination == .cancelled)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let helper = try #require(pid_t(pidText))
        // The helper got the same signal through the process group. Give the kernel a moment to reap it.
        var alive = true
        for _ in 0..<100 where alive {
            alive = kill(helper, 0) == 0
            if alive { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(!alive)
    }

    @Test func timeoutIsCountedFromTheLaunch() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\ntrap '' TERM\nexec sleep 30\n")

        let started = Date()
        let output = await run(script, in: scratch.url, timeout: 0.3, killGrace: 0.3)
        #expect(output.termination == .timedOut)
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func tooMuchOutputStopsTheProcessAndKeepsNothing() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\nhead -c 200000 /dev/zero\nsleep 30\n")

        let started = Date()
        let output = await run(script, in: scratch.url, maxOutputBytes: 1_000)
        #expect(output == ProcessOutput(termination: .outputLimitExceeded, stdout: Data()))
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func outputUpToTheLimitIsKept() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\nhead -c 1000 /dev/zero\n")

        let output = await run(script, in: scratch.url, maxOutputBytes: 1_000)
        #expect(output.termination == .exited(0))
        #expect(output.stdout.count == 1_000)
    }

    /// Waits until the process `pidFile` names is gone (reaped), or about 5 s.
    private func isGone(pidFile: URL) async throws -> Bool {
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return kill(pid, 0) != 0
    }

    @Test func aHelperHoldingTheOutputOpenDoesNotHoldTheRunAndIsStopped() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let pidFile = scratch.url.appendingPathComponent("helper.pid")
        // The background `sleep` inherits standard output, so its end never arrives while it runs.
        let script = try scratch.file(
            "tool", contents: "#!/bin/sh\nsleep 20 &\necho $! > \"\(pidFile.path)\"\necho hi\nexit 0\n")

        let started = Date()
        let output = await run(script, in: scratch.url, endOfOutputGrace: 0.3)
        #expect(output == ProcessOutput(termination: .exited(0), stdout: Data("hi\n".utf8)))
        // Far less than the helper's 20 s, and the helper it left behind does not outlive the run.
        #expect(Date().timeIntervalSince(started) < 15)
        #expect(try await isGone(pidFile: pidFile))
    }

    @Test func cancellingAfterTheToolExitedStopsItsHelpersAndKeepsItsResult() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let pidFile = scratch.url.appendingPathComponent("helper.pid")
        let exited = scratch.url.appendingPathComponent("exited")
        let script = try scratch.file(
            "tool",
            contents:
                "#!/bin/sh\nsleep 30 &\necho $! > \"\(pidFile.path)\"\necho hi\ntouch \"\(exited.path)\"\nexit 0\n")
        let directory = scratch.url
        let environment = self.environment

        // A long wait for the end of output, so the cancellation lands while the helper still holds it open.
        let task = Task {
            await BoundedProcess.run(
                executable: script, arguments: [], environment: environment, currentDirectory: directory,
                timeout: 60, killGrace: 0.3, maxOutputBytes: 1_000, endOfOutputGrace: 30)
        }
        for _ in 0..<600 where !FileManager.default.fileExists(atPath: exited.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        // Time for Process to report the exit even on a busy CI machine; the cancellation must land after it.
        try await Task.sleep(for: .seconds(3))
        let cancelled = Date()
        task.cancel()
        let output = await task.value

        // The tool itself finished: its result stands (a finished run must still be judged), only the helper goes.
        #expect(output == ProcessOutput(termination: .exited(0), stdout: Data("hi\n".utf8)))
        #expect(Date().timeIntervalSince(cancelled) < 15)
        #expect(try await isGone(pidFile: pidFile))
    }

    @Test func aMissingExecutableFailsToLaunch() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let output = await run(scratch.url.appendingPathComponent("nothing"), in: scratch.url)
        #expect(output == ProcessOutput(termination: .launchFailed, stdout: Data()))
    }

    @Test func aMissingWorkingDirectoryFailsToLaunch() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\necho hi\n")
        let output = await run(script, in: scratch.url.appendingPathComponent("gone", isDirectory: true))
        #expect(output.termination == .launchFailed)
    }

    @Test func cancellationStopsTheProcess() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let script = try scratch.file("tool", contents: "#!/bin/sh\nexec sleep 30\n")
        let directory = scratch.url
        let environment = self.environment

        let started = Date()
        let task = Task {
            await BoundedProcess.run(
                executable: script, arguments: [], environment: environment, currentDirectory: directory,
                timeout: 20, killGrace: 0.5, maxOutputBytes: 1_000)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let output = await task.value
        #expect(output == ProcessOutput(termination: .cancelled, stdout: Data()))
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test func alreadyCancelledNeverLaunches() async throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let marker = scratch.url.appendingPathComponent("ran")
        let script = try scratch.file("tool", contents: "#!/bin/sh\ntouch \"\(marker.path)\"\n")
        let directory = scratch.url
        let environment = self.environment

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BoundedProcess.run(
                executable: script, arguments: [], environment: environment, currentDirectory: directory,
                timeout: 5, maxOutputBytes: 1_000)
        }
        let output = await task.value
        #expect(output.termination == .cancelled)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
