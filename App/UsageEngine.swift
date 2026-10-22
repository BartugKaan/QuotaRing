import AppKit
import Foundation
import Network
import Observation
import QuotaRingCore
import os

/// Runs the data loops and reports results to ``AppModel``.
///
/// - **Cache loop:** every 30 s, compares the fingerprint of Claude Code's `.claude.json` and re-reads it only when it
///   changed. A failed read keeps the previous snapshot.
/// - **Live loop** (only with consent and completed onboarding): asks the endpoint when the freshest snapshot is older
///   than the refresh interval, with jitter and back-off from ``RefreshPlanner``. After the user refused Keychain
///   access it asks nothing until the user presses Refresh or turns Live mode off and on.
/// - **Auto-refresh loop** (only with consent and completed onboarding): runs Claude Code's own `/usage` through
///   ``CLIRefresher`` when the freshest snapshot is older than the refresh interval, at most every 120 s, with the
///   same back-off as Live mode, then re-reads the cache at once. If Claude Code ever answers with a model request, it
///   turns the feature off.
/// - **Transcripts:** scanned when the popover opens and every 60 s while it stays open. A scan under way stops when
///   the popover closes and carries on from there the next time.
/// - Pauses everything on system sleep, and Live and auto-refresh while offline or while nobody can look at the numbers
///   (all displays asleep, the user's session in the background, the screen locked; see ``UserPresence``). The cache
///   check goes on, it costs a `stat`. Resumes on wake, reconnect and return, with an immediate check of what is due.
/// - Persists the last good snapshot (no secrets), bound to the config directory it came from, and loads it at launch.
///
/// All state lives on the main actor; file, Keychain and network work runs in detached tasks or on dedicated queues.
@MainActor
final class UsageEngine {
    enum Event {
        /// The snapshot to show changed. `isNew` is `false` for the one loaded from disk at launch.
        case snapshot(UsageSnapshot?, isNew: Bool)
        case liveStatus(LiveStatus)
        case refreshing(Bool)
        case coolingDown(Bool)
        case activity([ActivityRange: UsageBreakdown], [DailyTokens])
        /// Claude Code's cache file exists but cannot be used (see ``CacheReadHealth``); `nil` once it can again.
        case cacheProblem(CacheReadError?)
        case cliStatus(CLIRefreshStatus)
        /// Where Claude Code's command-line tool is and what it is, for Settings.
        case cliBinary(CLIBinaryState)
    }

    var onEvent: (Event) -> Void = { _ in }

    private static let cacheCheckInterval: Duration = .seconds(30)
    private static let transcriptScanInterval: Duration = .seconds(60)
    /// Saves and deletes of the last snapshot run here one after another, so a delete lands after any pending save.
    private static let persistenceQueue = DispatchQueue(
        label: "io.github.bartugkaan.QuotaRing.persistence", qos: .utility)

    private let settings: SettingsStore
    private let snapshotStore: LastSnapshotStore?
    private let userAgent: String
    private lazy var transport = URLSessionTransport()

    // Sources, rebuilt when the config directory changes.
    private var paths: ClaudePaths
    private var cacheReader: ClaudeCodeCacheReader
    private var scanner: TranscriptScanner
    private var cacheFingerprint: FileFingerprint?
    private var hasReadCache = false
    private var cacheHealth = CacheReadHealth()
    private var reportedCacheProblem: CacheReadError?

    // Candidates for the snapshot on screen.
    private var candidates = SnapshotCandidates()
    private var selected: UsageSnapshot?

    // Live state.
    private var liveStatus: LiveStatus = .off
    private var consecutiveFailures = 0
    private var nextAllowedLiveAt: Date?
    private var lastLiveAttemptAt: Date?
    private var cycleInterval: TimeInterval
    private var isLiveFetchInFlight = false
    /// The user refused Keychain access: no automatic request until they press Refresh or toggle Live mode.
    private var isLiveSuspended = false
    /// No Live request (automatic or manual) before this time, while another system prompt may be on screen.
    private var liveHoldUntil: Date?
    /// Changes whenever the signed-in account may have changed (an account mismatch begins, or another config
    /// directory is chosen). A Live request remembers the value it started with; if it changed meanwhile, the token it
    /// read may belong to the previous account, so the request is not sent or its result is dropped.
    private var accountGeneration = 0

    // Auto-refresh state.
    private let cliRefresher = CLIRefresher()
    private var cliStatus: CLIRefreshStatus = .off
    private var cliConsecutiveFailures = 0
    private var cliNextAllowedAt: Date?
    /// When the last run started, successful or not: runs are spaced by this.
    private var lastCLIRunAt: Date?
    private var lastCLISuccessAt: Date?
    private var cliCycleInterval: TimeInterval
    private var isCLIRunInFlight = false
    /// Runs in a row that exited normally with output that could not be checked (see ``RefreshPlanner/cliSafety``).
    private var cliUnverifiedRuns = 0

    // System state.
    private var isStarted = false
    private var isShutDown = false
    private var isAsleep = false
    private var isOnline = true
    /// Whether anybody can look at the numbers; Live and auto-refresh are paused while not.
    private var presence = UserPresence()
    private var isPopoverOpen = false

    // Settings as last applied, to tell which change happened.
    private var appliedLiveActive: Bool
    private var appliedCLIActive: Bool
    private var appliedCLIPath: URL?
    private var appliedRefreshInterval: TimeInterval
    private var appliedConfigDirectory: URL?

    private var resumeTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    /// The transcript scan under way, from either the loop or a refresh. At most one at a time.
    private var scanWork: Task<([ActivityRange: UsageBreakdown], [DailyTokens]), Never>?
    private var cooldownTask: Task<Void, Never>?
    /// The Live request of a manual refresh, so it can be cancelled like the loop's.
    private var manualLiveTask: Task<Void, Never>?
    private var cliTask: Task<Void, Never>?
    /// The auto-refresh run of a manual refresh, so it can be cancelled like the loop's.
    private var manualCLITask: Task<CLIRefreshOutcome?, Never>?
    private var pathMonitor: NWPathMonitor?
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var screenLockObserver: ScreenLockObserver?

    init(settings: SettingsStore, snapshotStore: LastSnapshotStore? = .standard()) {
        self.settings = settings
        self.snapshotStore = snapshotStore
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        userAgent = UsageAPI.userAgent(version: version)

        paths = ClaudePaths(customConfigDirectory: settings.customConfigDirectory)
        cacheReader = ClaudeCodeCacheReader(fileURL: paths.globalConfigFile)
        scanner = TranscriptScanner(projectsDirectory: paths.projectsDirectory)
        cycleInterval = settings.refreshInterval
        cliCycleInterval = settings.refreshInterval

        appliedLiveActive = settings.isLiveModeActive
        appliedCLIActive = settings.isCLIRefreshActive
        appliedCLIPath = settings.customCLIPath
        appliedRefreshInterval = settings.refreshInterval
        appliedConfigDirectory = settings.customConfigDirectory
    }

    // MARK: - Control

    func start() {
        guard !isStarted else { return }
        isStarted = true

        candidates = SnapshotCandidates(persisted: snapshotStore?.load(configDirectory: paths.configDirectory))
        if let persisted = candidates.persisted {
            selected = persisted
            onEvent(.snapshot(persisted, isNew: false))
            engineLog.info("Loaded the last snapshot from disk")
        }
        cycleInterval = jitteredInterval()
        cliCycleInterval = jitteredInterval()
        setLiveStatus(settings.isLiveModeActive ? .ok : .off)
        setCLIStatus(idleCLIStatus)
        inspectCLI()

        observeSettings()
        observeWorkspace()
        startPathMonitor()
        resume()
    }

    /// Stops every loop and any running request or Claude Code run, at once: cancelling a run sends its process group
    /// `SIGTERM` synchronously, before the app goes away. Called when the app quits.
    func shutDown() {
        guard isStarted else { return }
        engineLog.info("Shutting down")
        isShutDown = true
        pauseAll()
        cancelTranscriptScan()
        cooldownTask?.cancel()
        cooldownTask = nil
    }

    func refresh(userInitiated: Bool) async {
        onEvent(.refreshing(true))
        defer { onEvent(.refreshing(false)) }

        // Somebody pressed Refresh, so somebody is there, whatever a missed notification says.
        if userInitiated {
            presenceDidChange(.userInteracted)
        }
        await checkCache(force: true)

        if userInitiated, settings.isLiveModeActive || settings.isCLIRefreshActive {
            startCooldown()
        }

        // Auto-refresh first: it needs no token and, when it works, makes the Live request unnecessary.
        var refreshedThroughCLI = false
        if userInitiated, settings.isCLIRefreshActive, isOnline, !isAsleep,
            RefreshPlanner.manualCLIRefreshAllowed(lastRunAt: lastCLIRunAt, now: Date())
        {
            let task = Task { [weak self] () -> CLIRefreshOutcome? in
                await self?.performCLIRefresh()
            }
            manualCLITask = task
            let outcome = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            if manualCLITask == task {
                manualCLITask = nil
            }
            refreshedThroughCLI = outcome == .success
        }

        var liftedLiveSuspension = false
        if userInitiated, settings.isLiveModeActive {
            if isLiveSuspended {
                // Refresh is how the user says "ask again" after refusing Keychain access.
                isLiveSuspended = false
                liftedLiveSuspension = true
                liveLog.info("Keychain refusal lifted by a manual refresh")
            }
            let manualAllowedAt = manualLiveAllowedAt()
            if !refreshedThroughCLI, isOnline,
                RefreshPlanner.shouldFetchLive(
                    liveEnabled: true, freshest: nil, now: Date(), refreshInterval: 0,
                    nextAllowedLiveAt: manualAllowedAt)
            {
                let task = Task { [weak self] in
                    guard let self else { return }
                    await self.performLiveFetch()
                }
                manualLiveTask = task
                await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
                if manualLiveTask == task {
                    manualLiveTask = nil
                }
            }
        }
        // While suspended, the Live loop sleeps for the longest wait. Wake it now that automatic requests are allowed
        // again, but only after the manual request: it has either settled the matter or suspended them again, and the
        // loop does not start a second request next to it.
        if liftedLiveSuspension, !isShutDown {
            restartLiveLoop()
        }
        if isPopoverOpen {
            await scanTranscripts()
        }
    }

    func setPopoverOpen(_ open: Bool) {
        guard open != isPopoverOpen else { return }
        isPopoverOpen = open
        if open {
            presenceDidChange(.userInteracted)
        } else {
            // Nobody sees the numbers of a scan that is still reading, and a scan carries on from where it stopped.
            cancelTranscriptScan()
        }
        restartTranscriptLoop()
    }

    /// Makes Live mode wait until `deadline` before reading the Keychain, because another system prompt (the
    /// notification permission) may be on screen. ``releaseLiveHold()`` ends the wait early.
    func holdLiveRequests(until deadline: Date) {
        liveHoldUntil = max(liveHoldUntil ?? deadline, deadline)
        engineLog.info("Live requests held while another prompt may be open")
    }

    /// Ends a wait started with ``holdLiveRequests(until:)``.
    func releaseLiveHold() {
        guard liveHoldUntil != nil else { return }
        liveHoldUntil = nil
        restartLiveLoop()
    }

    // MARK: - Loops

    /// Reads the cache once, then (re)starts every loop that should run now.
    private func resume() {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            guard let self else { return }
            await self.checkCache(force: false)
            guard !Task.isCancelled, !self.isAsleep else { return }
            self.restartCacheLoop()
            self.restartLiveLoop()
            self.restartCLILoop()
            self.restartTranscriptLoop()
        }
    }

    private func pauseAll() {
        resumeTask?.cancel()
        cacheTask?.cancel()
        liveTask?.cancel()
        transcriptTask?.cancel()
        cliTask?.cancel()
        resumeTask = nil
        cacheTask = nil
        liveTask = nil
        transcriptTask = nil
        cliTask = nil
        cancelManualLiveFetch()
        cancelManualCLIRefresh()
    }

    /// Applies a change of whether anybody can look at the numbers. Not private so that tests can feed it.
    func presenceDidChange(_ signal: UserPresence.Signal) {
        switch presence.apply(signal) {
        case .none:
            break
        case .wentAway:
            engineLog.info(
                "Nobody is looking (\(self.presence.logName, privacy: .public)); pausing Live and auto-refresh")
            // Not the manual tasks: a refresh the user asked for finishes. The cache check and the status item go on.
            liveTask?.cancel()
            liveTask = nil
            cliTask?.cancel()
            cliTask = nil
        case .cameBack:
            // Nothing to resume before the start, after shutting down, or while asleep: the wake from sleep resumes.
            guard isStarted, !isShutDown, !isAsleep else { return }
            engineLog.info("Somebody is back; resuming")
            resume()
        }
    }

    /// Whether Live and auto-refresh are paused because nobody can look at the numbers.
    var isUserAway: Bool {
        presence.isAway
    }

    private func cancelManualLiveFetch() {
        manualLiveTask?.cancel()
        manualLiveTask = nil
    }

    private func cancelManualCLIRefresh() {
        manualCLITask?.cancel()
        manualCLITask = nil
    }

    private func restartCacheLoop() {
        cacheTask?.cancel()
        cacheTask = nil
        guard !isAsleep else { return }
        cacheTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.cacheCheckInterval)
                guard !Task.isCancelled, let self else { return }
                await self.checkCache(force: false)
            }
        }
    }

    /// Whether the Live and auto-refresh loops may run now: awake, online and somebody can look at the numbers.
    private var mayRunAutomaticRequests: Bool {
        RefreshPlanner.automaticRequestsMayRun(isAsleep: isAsleep, isOnline: isOnline, presence: presence)
    }

    private func restartLiveLoop() {
        liveTask?.cancel()
        liveTask = nil
        guard settings.isLiveModeActive, mayRunAutomaticRequests else { return }
        liveTask = Task { [weak self] in
            await self?.runLiveLoop()
        }
    }

    private func runLiveLoop() async {
        while !Task.isCancelled {
            if RefreshPlanner.shouldFetchLive(
                liveEnabled: settings.isLiveModeActive,
                freshest: selected,
                now: Date(),
                refreshInterval: cycleInterval,
                nextAllowedLiveAt: liveNotBefore,
                isSuspended: isLiveSuspended
            ) {
                await performLiveFetch()
            }
            guard !Task.isCancelled else { return }
            // After a Keychain refusal nothing can become due by itself: sleep long instead of waking every second. The
            // loop is restarted where the suspension is lifted.
            let delay = RefreshPlanner.nextCheckDelay(
                freshest: selected,
                now: Date(),
                refreshInterval: cycleInterval,
                nextAllowedLiveAt: liveNotBefore,
                isSuspended: isLiveSuspended
            )
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func restartCLILoop() {
        cliTask?.cancel()
        cliTask = nil
        guard settings.isCLIRefreshActive, mayRunAutomaticRequests else { return }
        cliTask = Task { [weak self] in
            await self?.runCLILoop()
        }
    }

    private func runCLILoop() async {
        while !Task.isCancelled {
            if RefreshPlanner.shouldRunCLIRefresh(
                enabled: settings.isCLIRefreshActive,
                freshest: selected,
                now: Date(),
                refreshInterval: cliCycleInterval,
                lastRunAt: lastCLIRunAt,
                nextAllowedAt: cliNextAllowedAt
            ) {
                await performCLIRefresh()
            }
            guard !Task.isCancelled else { return }
            let delay = RefreshPlanner.nextCLICheckDelay(
                freshest: selected,
                now: Date(),
                refreshInterval: cliCycleInterval,
                lastRunAt: lastCLIRunAt,
                nextAllowedAt: cliNextAllowedAt
            )
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func restartTranscriptLoop() {
        transcriptTask?.cancel()
        transcriptTask = nil
        guard isPopoverOpen, !isAsleep else { return }
        transcriptTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scanTranscripts()
                try? await Task.sleep(for: Self.transcriptScanInterval)
            }
        }
    }

    // MARK: - Claude Code cache

    /// What one look at the cache came to, for callers that need to know.
    private enum CacheCheck {
        case unchanged
        case read(UsageSnapshot?)
        case failed(CacheReadError)
        /// Another config directory was chosen while the file was read; the result was dropped.
        case directoryChanged
    }

    private enum CacheOutcome: Sendable {
        case unchanged
        case read(FileFingerprint?, UsageSnapshot?)
        case failed(FileFingerprint?, CacheReadError)
    }

    /// Reads Claude Code's cache (only when it changed, unless `force`).
    @discardableResult
    private func checkCache(force: Bool) async -> CacheCheck {
        let reader = cacheReader
        let previous = cacheFingerprint
        let compare = hasReadCache && !force
        let outcome = await Task.detached(priority: .utility) {
            Self.readCache(reader, previous: previous, compare: compare)
        }.value

        // The config directory may have changed while the read was running.
        guard reader.fileURL == cacheReader.fileURL else { return .directoryChanged }

        let check: CacheCheck
        switch outcome {
        case .unchanged:
            check = .unchanged
        case .read(let fingerprint, let snapshot):
            check = .read(snapshot)
            cacheFingerprint = fingerprint
            hasReadCache = true
            cacheHealth.recordSuccess()
            if candidates.recordCacheRead(snapshot) {
                reselect()
            }
        case .failed(let fingerprint, .accountMismatch):
            check = .failed(.accountMismatch)
            cacheFingerprint = fingerprint
            hasReadCache = true
            cacheHealth.recordFailure(.accountMismatch, at: Date())
            // The cache belongs to an account that is no longer signed in: whatever was read before, from the cache,
            // from disk or from Live mode with the previous account's login, must not stay on screen or be saved again.
            if candidates.recordAccountMismatch() {
                cacheLog.notice("Cached usage belongs to another account; dropping everything read so far")
                // A Live request already under way may carry the previous account's token: its result must not land.
                accountGeneration += 1
                // The previous account's back-off says nothing about the new login: ask for the new account's usage now.
                nextAllowedLiveAt = nil
                consecutiveFailures = 0
                deletePersistedSnapshot()
                reselect()
                restartLiveLoop()
            }
        case .failed(let fingerprint, let error):
            check = .failed(error)
            // Torn reads are expected while Claude Code rewrites the file: keep the previous snapshot and try again
            // when the file changes next. One that lasts is shown (see `CacheReadHealth`).
            cacheFingerprint = fingerprint
            hasReadCache = true
            cacheHealth.recordFailure(error, at: Date())
            cacheLog.notice("Cache read failed (\(error.logName, privacy: .public)); keeping the previous snapshot")
        }
        reportCacheProblem()
        return check
    }

    private func reportCacheProblem() {
        let problem = cacheHealth.problem(at: Date())
        guard problem != reportedCacheProblem else { return }
        reportedCacheProblem = problem
        onEvent(.cacheProblem(problem))
    }

    private nonisolated static func readCache(
        _ reader: ClaudeCodeCacheReader,
        previous: FileFingerprint?,
        compare: Bool
    ) -> CacheOutcome {
        // Fingerprint first: if the file changes during the read, the next check sees a newer fingerprint and reads
        // again.
        let fingerprint = reader.fingerprint()
        if compare, fingerprint == previous {
            return .unchanged
        }
        do {
            return .read(fingerprint, try reader.read())
        } catch let error as CacheReadError {
            return .failed(fingerprint, error)
        } catch {
            return .failed(fingerprint, .unreadable)
        }
    }

    // MARK: - Live endpoint

    private func manualLiveAllowedAt() -> Date? {
        var allowed = lastLiveAttemptAt?.addingTimeInterval(RefreshPlanner.minimumLiveSpacing)
        if case .rateLimited(let until) = liveStatus {
            allowed = max(allowed ?? until, until)
        }
        if let liveHoldUntil {
            allowed = max(allowed ?? liveHoldUntil, liveHoldUntil)
        }
        return allowed
    }

    /// The earliest time of the next automatic Live request: after the back-off and after any hold.
    private var liveNotBefore: Date? {
        [nextAllowedLiveAt, liveHoldUntil].compactMap { $0 }.max()
    }

    private func performLiveFetch() async {
        guard settings.isLiveModeActive else { return }
        let started = Date()
        let spacedOut = started.addingTimeInterval(RefreshPlanner.minimumLiveSpacing)
        guard !isLiveFetchInFlight else {
            // The other request may wait on a Keychain prompt for minutes: look again later, not every second.
            nextAllowedLiveAt = max(nextAllowedLiveAt ?? started, spacedOut)
            return
        }
        isLiveFetchInFlight = true
        defer { isLiveFetchInFlight = false }

        lastLiveAttemptAt = started
        // Keep the loop from re-checking while this request runs; the result sets the real back-off below.
        nextAllowedLiveAt = max(nextAllowedLiveAt ?? started, spacedOut)

        let requestPaths = paths
        let generation = accountGeneration
        let request = LiveRequest(
            client: UsageAPIClient(transport: transport, userAgent: userAgent),
            paths: requestPaths,
            isStillAllowed: { [weak self] in
                self?.isLiveAllowed(for: requestPaths, generation: generation) ?? false
            }
        )
        let work = Task.detached(priority: .utility) { await request.run() }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        // Abandoned before anything was sent (cancelled, consent withdrawn, asleep or another directory).
        guard let result = outcome else { return }
        // A request cut off by sleep or by Live mode being turned off says nothing about the server.
        if case .failed(.network) = result, Task.isCancelled { return }
        // Results for a withdrawn consent, a config directory that is no longer selected or an account that is no
        // longer signed in do not apply: they are neither shown nor saved.
        guard isLiveAllowed(for: requestPaths, generation: generation) else { return }
        apply(result, now: Date())
    }

    /// Whether a Live request for `requestPaths`, started in account generation `generation`, may still go out (or its
    /// result still be used).
    private func isLiveAllowed(for requestPaths: ClaudePaths, generation: Int) -> Bool {
        settings.isLiveModeActive && !isAsleep && requestPaths == paths && generation == accountGeneration
    }

    private func apply(_ result: LiveFetchResult, now: Date) {
        let policy = PollingPolicy(baseInterval: settings.refreshInterval)
        let retry = RefreshPlanner.retry(
            after: result, consecutiveFailures: consecutiveFailures, policy: policy, random: .random(in: 0...1))
        consecutiveFailures = retry.consecutiveFailures
        nextAllowedLiveAt = now.addingTimeInterval(retry.delay)
        cycleInterval = jitteredInterval()

        let suspends = RefreshPlanner.suspendsAutomaticRequests(after: result)
        if suspends {
            if !isLiveSuspended {
                liveLog.notice("Keychain access was refused; no automatic Live requests until Refresh")
            }
            // Nothing was sent, so the one-a-minute spacing does not apply: the user's next Refresh asks at once.
            lastLiveAttemptAt = nil
        }
        isLiveSuspended = suspends

        if case .snapshot(let snapshot) = result {
            candidates.recordLive(snapshot)
            reselect()
        }
        setLiveStatus(RefreshPlanner.liveStatus(for: result, now: now, retryAfterFallback: retry.delay))
    }

    private func setLiveStatus(_ status: LiveStatus) {
        guard status != liveStatus else { return }
        liveStatus = status
        liveLog.info("Live status: \(status.logName, privacy: .public)")
        onEvent(.liveStatus(status))
    }

    private func jitteredInterval() -> TimeInterval {
        PollingPolicy(baseInterval: settings.refreshInterval)
            .nextDelay(after: .success, consecutiveFailures: 0, random: .random(in: 0...1))
    }

    private func startCooldown() {
        cooldownTask?.cancel()
        onEvent(.coolingDown(true))
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RefreshPlanner.minimumLiveSpacing))
            guard !Task.isCancelled else { return }
            self?.onEvent(.coolingDown(false))
        }
    }

    private func endCooldown() {
        cooldownTask?.cancel()
        cooldownTask = nil
        onEvent(.coolingDown(false))
    }

    // MARK: - Auto-refresh through Claude Code

    /// The status while no run has told anything new: ok when on, otherwise off, or why it was turned off.
    private var idleCLIStatus: CLIRefreshStatus {
        if settings.isCLIRefreshActive {
            return .ok(lastRun: lastCLISuccessAt)
        }
        return settings.cliRefreshSafetyStop.map { .disabledForSafety($0) } ?? .off
    }

    private var cliSettings: CLIRefresher.Settings {
        CLIRefresher.Settings(
            customCLIPath: settings.customCLIPath, customConfigDirectory: settings.customConfigDirectory)
    }

    /// Looks up where Claude Code's tool is (file metadata only, nothing is executed) and reports it for Settings.
    func inspectCLI() {
        let request = cliSettings
        let refresher = cliRefresher
        Task { [weak self] in
            let state = await refresher.locate(request)
            guard let self, request == self.cliSettings else { return }
            self.onEvent(.cliBinary(state))
        }
    }

    /// One run of Claude Code's `/usage`, then an immediate cache read. Returns the outcome, or `nil` when nothing ran
    /// or the run was abandoned (cancelled, turned off, asleep, or the settings it ran with changed).
    @discardableResult
    private func performCLIRefresh() async -> CLIRefreshOutcome? {
        guard settings.isCLIRefreshActive, !isCLIRunInFlight, !isAsleep, isOnline else { return nil }
        isCLIRunInFlight = true
        defer { isCLIRunInFlight = false }

        let started = Date()
        lastCLIRunAt = started
        let statusBefore = cliStatus
        setCLIStatus(.running)

        let requestPaths = paths
        let request = cliSettings
        let report = await cliRefresher.run(request)
        /// Whether the run no longer applies: cancelled, turned off, asleep, or run with settings no longer chosen.
        func isAbandoned() -> Bool {
            Task.isCancelled || report.outcome == .failed(.cancelled) || !settings.isCLIRefreshActive || isAsleep
                || requestPaths != paths || request != cliSettings
        }

        var cacheRead: CLICacheReadResult?
        if RefreshPlanner.cliRunNeedsCacheRead(outcome: report.outcome, abandoned: isAbandoned()) {
            // Do not wait for the cache loop's next look: the file was just rewritten.
            cacheRead = await readCacheAfterCLIRun()
        }
        let resolution = RefreshPlanner.resolveCLIRun(
            outcome: report.outcome, abandoned: isAbandoned(), cacheRead: cacheRead, runStartedAt: started)
        guard case .apply(let outcome) = resolution else {
            // Abandoned: the result says nothing about Claude Code.
            if cliStatus == .running {
                setCLIStatus(settings.isCLIRefreshActive ? statusBefore : idleCLIStatus)
            }
            return nil
        }
        onEvent(.cliBinary(report.binary))
        applyCLI(outcome, ranAt: started, binary: report.binary)
        return outcome
    }

    /// Reads the cache at once after a run that reported success, for ``RefreshPlanner/resolveCLIRun``.
    private func readCacheAfterCLIRun() async -> CLICacheReadResult {
        switch await checkCache(force: true) {
        case .read(let snapshot):
            return .read(fetchedAt: snapshot?.fetchedAt)
        case .unchanged:
            // Not expected from a forced read; the entry held is then the latest.
            return .read(fetchedAt: candidates.cached?.fetchedAt)
        case .failed(let error):
            return .failed(error)
        case .directoryChanged:
            return .configDirectoryChanged
        }
    }

    private func applyCLI(_ outcome: CLIRefreshOutcome, ranAt: Date, binary: CLIBinaryState) {
        let safety = RefreshPlanner.cliSafety(after: outcome, unverifiedRuns: cliUnverifiedRuns)
        cliUnverifiedRuns = safety.unverifiedRuns
        let policy = PollingPolicy(baseInterval: settings.refreshInterval)
        let retry = RefreshPlanner.cliRetry(
            after: outcome, consecutiveFailures: cliConsecutiveFailures, policy: policy, random: .random(in: 0...1))
        cliConsecutiveFailures = retry.consecutiveFailures
        cliNextAllowedAt = Date().addingTimeInterval(retry.delay)
        cliCycleInterval = jitteredInterval()
        if outcome == .success {
            lastCLISuccessAt = ranAt
        }
        if let stop = safety.stop {
            autoRefreshLog.error("Auto-refresh turned itself off for safety (\(stop.rawValue, privacy: .public))")
            settings.stopCLIRefreshForSafety(stop)
            setCLIStatus(.disabledForSafety(stop))
            return
        }
        setCLIStatus(RefreshPlanner.cliStatus(after: outcome, ranAt: ranAt, binary: binary))
    }

    private func setCLIStatus(_ status: CLIRefreshStatus) {
        guard status != cliStatus else { return }
        cliStatus = status
        autoRefreshLog.info("Auto-refresh status: \(status.logName, privacy: .public)")
        onEvent(.cliStatus(status))
    }

    /// Forgets failures and back-off: the tool, the consent or the account changed, so earlier failures say nothing.
    private func resetCLIBackoff() {
        cliConsecutiveFailures = 0
        cliNextAllowedAt = nil
    }

    // MARK: - Transcripts

    private func scanTranscripts() async {
        guard scanWork == nil else { return }

        let scanner = self.scanner
        let now = Date()
        let sessionResetsAt = selected?.session(at: now)?.resetsAt
        let work = Task.detached(priority: .utility) {
            let entries = await scanner.scan()
            // A cancelled scan may be incomplete, and nobody is waiting for it.
            guard !Task.isCancelled else { return ([ActivityRange: UsageBreakdown](), [DailyTokens]()) }
            return Self.aggregate(entries, now: now, sessionResetsAt: sessionResetsAt, calendar: .current)
        }
        scanWork = work
        // Cancelling whoever waits (the loop, when the popover closes) cancels the scan, which stops at its next file or
        // chunk and keeps what it read.
        let (activity, daily) = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        if scanWork == work {
            scanWork = nil
        }

        // Results of a cancelled scan, and from a projects directory that is no longer configured, are dropped.
        guard !work.isCancelled, scanner === self.scanner else { return }
        onEvent(.activity(activity, daily))
    }

    /// Stops the transcript scan under way, if any. What it has read is kept by the scanner.
    private func cancelTranscriptScan() {
        scanWork?.cancel()
        scanWork = nil
    }

    private nonisolated static func aggregate(
        _ entries: [TranscriptEntry],
        now: Date,
        sessionResetsAt: Date?,
        calendar: Calendar
    ) -> ([ActivityRange: UsageBreakdown], [DailyTokens]) {
        let fiveHours: TimeInterval = 5 * 3600
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        let sessionStart =
            sessionResetsAt.map { $0.addingTimeInterval(-fiveHours) } ?? now.addingTimeInterval(-fiveHours)

        func interval(from start: Date) -> DateInterval {
            DateInterval(start: min(start, now), end: now)
        }

        let activity: [ActivityRange: UsageBreakdown] = [
            .session: UsageAggregator.breakdown(entries, in: interval(from: sessionStart)),
            .today: UsageAggregator.breakdown(entries, in: interval(from: today)),
            .week: UsageAggregator.breakdown(entries, in: interval(from: weekStart)),
        ]
        let daily = UsageAggregator.daily(entries, days: 7, endingAt: now, calendar: calendar)
        return (activity, daily)
    }

    // MARK: - Snapshot selection and persistence

    private func reselect() {
        let freshest = candidates.freshest
        guard freshest != selected else { return }
        selected = freshest
        onEvent(.snapshot(freshest, isNew: true))
        if let freshest {
            savePersistedSnapshot(freshest)
        }
    }

    private func savePersistedSnapshot(_ snapshot: UsageSnapshot) {
        guard let snapshotStore else { return }
        let configDirectory = paths.configDirectory
        Self.persistenceQueue.async {
            do {
                try snapshotStore.save(snapshot, configDirectory: configDirectory)
            } catch {
                persistenceLog.error("Could not save the last snapshot")
            }
        }
    }

    private func deletePersistedSnapshot() {
        guard let snapshotStore else { return }
        Self.persistenceQueue.async {
            do {
                try snapshotStore.delete()
            } catch {
                persistenceLog.error("Could not delete the last snapshot")
            }
        }
    }

    // MARK: - Settings, sleep and reachability

    private func observeSettings() {
        withObservationTracking {
            _ = settings.isLiveModeActive
            _ = settings.isCLIRefreshActive
            _ = settings.customCLIPath
            _ = settings.refreshInterval
            _ = settings.customConfigDirectory
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.settingsDidChange()
                self.observeSettings()
            }
        }
    }

    private func settingsDidChange() {
        if settings.customConfigDirectory != appliedConfigDirectory {
            appliedConfigDirectory = settings.customConfigDirectory
            switchConfigDirectory()
        }
        if settings.refreshInterval != appliedRefreshInterval {
            appliedRefreshInterval = settings.refreshInterval
            cycleInterval = jitteredInterval()
            cliCycleInterval = jitteredInterval()
            restartLiveLoop()
            restartCLILoop()
        }
        if settings.customCLIPath != appliedCLIPath {
            appliedCLIPath = settings.customCLIPath
            engineLog.info("Claude Code tool changed in Settings")
            cancelManualCLIRefresh()
            resetCLIBackoff()
            inspectCLI()
            restartCLILoop()
        }
        if settings.isCLIRefreshActive != appliedCLIActive {
            appliedCLIActive = settings.isCLIRefreshActive
            engineLog.info("Auto-refresh \(self.appliedCLIActive ? "enabled" : "disabled", privacy: .public)")
            resetCLIBackoff()
            if !appliedCLIActive {
                cancelManualCLIRefresh()
            }
            setCLIStatus(idleCLIStatus)
            inspectCLI()
            restartCLILoop()
        }
        if settings.isLiveModeActive != appliedLiveActive {
            appliedLiveActive = settings.isLiveModeActive
            engineLog.info("Live mode \(self.appliedLiveActive ? "enabled" : "disabled", privacy: .public)")
            setLiveStatus(appliedLiveActive ? .ok : .off)
            // Turning Live mode off and on is the other way to ask for the Keychain again after a refusal.
            isLiveSuspended = false
            if !appliedLiveActive {
                liveHoldUntil = nil
                endCooldown()
                cancelManualLiveFetch()
            }
            restartLiveLoop()
        }
    }

    /// A different Claude config directory may belong to a different account, so nothing read from the old one is
    /// kept: not in memory and not on disk.
    private func switchConfigDirectory() {
        engineLog.info("Claude config directory changed")
        cancelManualLiveFetch()
        cancelManualCLIRefresh()
        resetCLIBackoff()
        deletePersistedSnapshot()
        accountGeneration += 1
        paths = ClaudePaths(customConfigDirectory: settings.customConfigDirectory)
        cacheReader = ClaudeCodeCacheReader(fileURL: paths.globalConfigFile)
        cancelTranscriptScan()
        scanner = TranscriptScanner(projectsDirectory: paths.projectsDirectory)
        cacheFingerprint = nil
        hasReadCache = false
        cacheHealth = CacheReadHealth()
        reportCacheProblem()
        candidates = SnapshotCandidates()
        selected = nil
        onEvent(.snapshot(nil, isNew: false))
        onEvent(.activity([:], []))
        if !isAsleep {
            resume()
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemDidWake() }
            },
            // Whether anybody can look at the numbers: the displays, the user's session and the lock screen.
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.presenceDidChange(.displaysSlept) }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.presenceDidChange(.displaysWoke) }
            },
            center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.presenceDidChange(.sessionResigned) }
            },
            center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.presenceDidChange(.sessionBecameActive) }
            },
        ]
        screenLockObserver = ScreenLockObserver { [weak self] signal in
            self?.presenceDidChange(signal)
        }
    }

    private func systemWillSleep() {
        guard !isAsleep else { return }
        isAsleep = true
        engineLog.info("System will sleep; pausing")
        pauseAll()
    }

    private func systemDidWake() {
        guard isAsleep else { return }
        isAsleep = false
        engineLog.info("System woke; resuming")
        resume()
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        // Called on the monitor's own queue, so explicitly not main-actor isolated, whatever the SDK says about it.
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            guard let self else { return }
            Task { @MainActor in self.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.bartugkaan.QuotaRing.reachability", qos: .utility))
        pathMonitor = monitor
    }

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        engineLog.info("Network \(online ? "available" : "unavailable", privacy: .public)")
        restartLiveLoop()
        restartCLILoop()
    }
}

// MARK: - Live request

/// One Live request, run off the main actor.
///
/// The credential is read on a dedicated serial queue because a Keychain read can block its thread on an access
/// prompt; that must stall neither the UI nor Swift's cooperative thread pool. The token is re-read for every request,
/// held only in memory for its duration and dropped afterwards.
private struct LiveRequest: Sendable {
    let client: UsageAPIClient
    let paths: ClaudePaths
    /// Asked on the main actor right before the request is sent: consent, sleep and the selected config directory may
    /// all have changed while a Keychain prompt was open.
    let isStillAllowed: @MainActor @Sendable () -> Bool

    private static let credentialQueue = DispatchQueue(
        label: "io.github.bartugkaan.QuotaRing.credentials", qos: .utility)

    /// The fetch result, or `nil` when the request was abandoned before anything was sent.
    func run() async -> LiveFetchResult? {
        guard !Task.isCancelled else { return nil }
        let paths = self.paths
        let credential: Result<OAuthCredential, CredentialError> = await withCheckedContinuation { continuation in
            Self.credentialQueue.async {
                do throws(CredentialError) {
                    continuation.resume(returning: .success(try CredentialResolver.standard(paths: paths).resolve()))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
        guard !Task.isCancelled, await isStillAllowed() else { return nil }
        let fetcher = LiveUsageFetcher(
            client: client, credentials: { () throws(CredentialError) -> OAuthCredential in try credential.get() })
        return await fetcher.fetch()
    }
}

// MARK: - Logging

private let engineLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "engine")
private let cacheLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "cache")
private let liveLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "live")
private let persistenceLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "persistence")
private let autoRefreshLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "cli")

extension CacheReadError {
    fileprivate var logName: String {
        switch self {
        case .fileTooLarge: "fileTooLarge"
        case .unreadable: "unreadable"
        case .malformed: "malformed"
        case .accountMismatch: "accountMismatch"
        }
    }
}
