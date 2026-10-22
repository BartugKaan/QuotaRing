import Darwin
import Foundation

/// How a ``BoundedProcess`` run ended.
public enum ProcessTermination: Equatable, Sendable {
    /// The process exited by itself with this status.
    case exited(Int32)
    /// The process was ended by this signal, not by QuotaRing.
    case signaled(Int32)
    /// It ran past its time limit and was stopped.
    case timedOut
    /// It printed more than its output limit and was stopped.
    case outputLimitExceeded
    /// The task waiting for it was cancelled and the process was stopped.
    case cancelled
    /// It could not be started.
    case launchFailed
}

/// The result of a ``BoundedProcess`` run.
public struct ProcessOutput: Equatable, Sendable {
    public var termination: ProcessTermination
    /// Standard output, at most the run's limit. Empty when the run was stopped (time limit, output limit or
    /// cancellation): a stopped run's output is never used.
    public var stdout: Data

    public init(termination: ProcessTermination, stdout: Data) {
        self.termination = termination
        self.stdout = stdout
    }
}

/// Runs one program with hard limits, for executing Claude Code's command-line tool.
///
/// - No shell: the executable and an argument array are passed as they are.
/// - The environment is exactly the one given; nothing is inherited.
/// - Standard input is `/dev/null`; standard error is discarded; standard output is collected up to a limit.
/// - Past the time limit, past the output limit or when the waiting task is cancelled, the process group gets
///   `SIGTERM`, then `SIGKILL` after a grace period. (`Process` starts the child in its own process group, so helpers
///   it started are stopped too.)
/// - Helpers the program leaves running after it exited are stopped as well, while the run is still under way: if
///   they hold its output open when the run ends, or when the run is stopped in the meantime. The program's own result
///   (its exit and output) is kept in that case, because it did finish.
/// - Never blocks a thread of Swift's cooperative pool, nor the caller of a cancellation: the launch (which can take a
///   while, for example while macOS checks a newly installed binary) and all watching happen on a Dispatch queue.
///
/// All `Process`, `Pipe` and `FileHandle` objects stay inside one run; nothing of them crosses an isolation boundary.
public enum BoundedProcess {
    /// - Parameters:
    ///   - timeout: Seconds the process may run, counted from its launch.
    ///   - killGrace: Seconds between `SIGTERM` and `SIGKILL`.
    ///   - maxOutputBytes: The most standard output kept; more stops the run.
    ///   - endOfOutputGrace: After the process exited, how long to wait for the end of its output. A helper it left
    ///     behind may hold the pipe open; the run does not wait for it.
    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL,
        timeout: TimeInterval,
        killGrace: TimeInterval = 2,
        maxOutputBytes: Int,
        endOfOutputGrace: TimeInterval = 1
    ) async -> ProcessOutput {
        let run = Run(
            executable: executable, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory, timeout: timeout, killGrace: killGrace,
            maxOutputBytes: maxOutputBytes, endOfOutputGrace: endOfOutputGrace)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                run.begin(continuation)
            }
        } onCancel: {
            run.stop(.cancelled)
        }
    }

    /// One run's state. Every mutable property is guarded by `lock`, which is never held while launching or waiting;
    /// callbacks arrive on Dispatch queues.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let timeout: TimeInterval
        private let killGrace: TimeInterval
        private let maxOutputBytes: Int
        private let endOfOutputGrace: TimeInterval
        private let queue = DispatchQueue(label: "io.github.bartugkaan.QuotaRing.bounded-process", qos: .utility)

        private let process = Process()
        private let pipe = Pipe()

        private var continuation: CheckedContinuation<ProcessOutput, Never>?
        private var output = Data()
        /// Why QuotaRing stops the run; the first reason wins.
        private var stopReason: ProcessTermination?
        /// How the process ended, once it did.
        private var exit: ProcessTermination?
        private var reachedEndOfOutput = false
        /// `process.run()` returned successfully: the process may be signaled.
        private var isLaunched = false
        private var isFinished = false

        init(
            executable: URL,
            arguments: [String],
            environment: [String: String],
            currentDirectory: URL,
            timeout: TimeInterval,
            killGrace: TimeInterval,
            maxOutputBytes: Int,
            endOfOutputGrace: TimeInterval
        ) {
            self.timeout = max(0, timeout)
            self.killGrace = max(0, killGrace)
            self.maxOutputBytes = max(0, maxOutputBytes)
            self.endOfOutputGrace = max(0, endOfOutputGrace)

            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = currentDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardOutput = pipe
        }

        /// Stores the continuation and launches on the run's queue.
        func begin(_ continuation: CheckedContinuation<ProcessOutput, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            queue.async { [self] in
                launch()
            }
        }

        private func launch() {
            lock.lock()
            // Cancelled before it started: nothing to launch.
            guard stopReason == nil else {
                lock.unlock()
                finish()
                return
            }
            lock.unlock()

            // Weak: the run is kept alive by its caller until it ends; a callback after that has nothing to do.
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                self?.received(chunk)
            }
            process.terminationHandler = { [weak self] process in
                self?.exited(reason: process.terminationReason, status: process.terminationStatus)
            }

            let launched: Bool
            do {
                try process.run()
                launched = true
            } catch {
                launched = false
            }

            lock.lock()
            isLaunched = launched
            if !launched {
                stopReason = .launchFailed
            }
            // A stop that arrived during the launch could not signal anything yet.
            let pendingStop = launched && stopReason != nil
            lock.unlock()

            guard launched else {
                finish()
                return
            }
            if pendingStop {
                terminate()
            } else {
                queue.asyncAfter(deadline: .now() + timeout) { [self] in
                    stop(.timedOut)
                }
            }
        }

        /// Stops the process for `reason`, unless the run already ended or is being stopped for another reason.
        func stop(_ reason: ProcessTermination) {
            lock.lock()
            guard !isFinished, stopReason == nil else {
                lock.unlock()
                return
            }
            if exit != nil, reason != .outputLimitExceeded {
                // The program itself finished; only helpers it left behind can remain. Its result stands.
                let helpersRemain = !reachedEndOfOutput
                lock.unlock()
                if helpersRemain { signalLeftoverHelpers() }
                return
            }
            stopReason = reason
            let launched = isLaunched
            lock.unlock()

            // Not launched yet: `launch` sees the reason, and either ends the run without launching or, if
            // `process.run()` is under way, terminates the process as soon as it returns.
            if launched {
                terminate()
            }
        }

        /// `SIGTERM` to the process group now, `SIGKILL` after the grace period, and a final deadline after which the
        /// run ends even without a termination report.
        private func terminate() {
            signal(SIGTERM)
            queue.asyncAfter(deadline: .now() + killGrace) { [self] in
                signal(SIGKILL)
            }
            queue.asyncAfter(deadline: .now() + killGrace + endOfOutputGrace + 1) { [self] in
                finish()
            }
        }

        /// Sends `signal` to the process group while the process has not been reported as ended.
        private func signal(_ signal: Int32) {
            lock.lock()
            defer { lock.unlock() }
            guard isLaunched, !isFinished else { return }
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            if exit == nil, process.isRunning {
                if kill(-pid, signal) != 0 {
                    kill(pid, signal)
                }
            } else if exit != nil, !reachedEndOfOutput {
                // The program exited, but something still holds its output open: normally a helper it started, which
                // is still in its process group (numbered after the program's pid), so the group still exists, and
                // POSIX does not reuse a pid while a group with that number exists. A helper could also have left the
                // group (setsid) and hold the pipe from elsewhere; then the group may be empty, `kill` fails with ESRCH,
                // and that helper is not reached. Only then could the number in theory belong to a new group: it would
                // need the pid to be recycled and become a group leader within the few seconds this run still lasts,
                // and a process of this user only, since nothing else can be signalled. That risk is negligible.
                kill(-pid, signal)
            }
        }

        /// `SIGKILL` to the helpers an exited program left running in its process group (see ``signal(_:)``).
        private func signalLeftoverHelpers() {
            signal(SIGKILL)
        }

        private func received(_ chunk: Data) {
            lock.lock()
            if chunk.isEmpty {
                pipe.fileHandleForReading.readabilityHandler = nil
                reachedEndOfOutput = true
                let ended = exit != nil
                lock.unlock()
                if ended { finish() }
                return
            }
            guard stopReason == nil else {
                // Stopping anyway: drain what still arrives, keep nothing.
                lock.unlock()
                return
            }
            if output.count + chunk.count > maxOutputBytes {
                output = Data()
                lock.unlock()
                stop(.outputLimitExceeded)
                return
            }
            output.append(chunk)
            lock.unlock()
        }

        private func exited(reason: Process.TerminationReason, status: Int32) {
            lock.lock()
            exit = reason == .uncaughtSignal ? .signaled(status) : .exited(status)
            let outputEnded = reachedEndOfOutput
            lock.unlock()
            if outputEnded {
                finish()
            } else {
                queue.asyncAfter(deadline: .now() + endOfOutputGrace) { [self] in
                    finish()
                }
            }
        }

        /// Ends the run once: stops reading, and hands back the output and how it ended. The read end of the pipe is not
        /// closed here, because a read may still be under way on another thread; it closes when the run is released.
        private func finish() {
            lock.lock()
            guard !isFinished, let continuation else {
                lock.unlock()
                return
            }
            // Helpers that still hold the output open when the run ends do not outlive it. The group is signalled under the
            // same reasoning as in `signal(_:)`: it normally still exists because they are in it.
            if exit != nil, !reachedEndOfOutput, isLaunched {
                let pid = process.processIdentifier
                if pid > 0 { kill(-pid, SIGKILL) }
            }
            isFinished = true
            self.continuation = nil
            let termination = stopReason ?? exit ?? .launchFailed
            let stdout = stopReason == nil ? output : Data()
            output = Data()
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.unlock()

            continuation.resume(returning: ProcessOutput(termination: termination, stdout: stdout))
        }
    }
}
