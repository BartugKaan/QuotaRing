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
/// - **Transcripts:** scanned when the popover opens and every 60 s while it stays open.
/// - Pauses on system sleep (and Live while offline), resumes on wake and reconnect.
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

    // System state.
    private var isStarted = false
    private var isAsleep = false
    private var isOnline = true
    private var isPopoverOpen = false
    private var isScanningTranscripts = false

    // Settings as last applied, to tell which change happened.
    private var appliedLiveActive: Bool
    private var appliedRefreshInterval: TimeInterval
    private var appliedConfigDirectory: URL?

    private var resumeTask: Task<Void, Never>?
    private var cacheTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var transcriptTask: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    /// The Live request of a manual refresh, so it can be cancelled like the loop's.
    private var manualLiveTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private var workspaceObservers: [any NSObjectProtocol] = []

    init(settings: SettingsStore, snapshotStore: LastSnapshotStore? = .standard()) {
        self.settings = settings
        self.snapshotStore = snapshotStore
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        userAgent = UsageAPI.userAgent(version: version)

        paths = ClaudePaths(customConfigDirectory: settings.customConfigDirectory)
        cacheReader = ClaudeCodeCacheReader(fileURL: paths.globalConfigFile)
        scanner = TranscriptScanner(projectsDirectory: paths.projectsDirectory)
        cycleInterval = settings.refreshInterval

        appliedLiveActive = settings.isLiveModeActive
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
        setLiveStatus(settings.isLiveModeActive ? .ok : .off)

        observeSettings()
        observeWorkspace()
        startPathMonitor()
        resume()
    }

    func refresh(userInitiated: Bool) async {
        onEvent(.refreshing(true))
        defer { onEvent(.refreshing(false)) }

        await checkCache(force: true)

        if userInitiated, settings.isLiveModeActive {
            if isLiveSuspended {
                // Refresh is how the user says "ask again" after refusing Keychain access.
                isLiveSuspended = false
                liveLog.info("Keychain refusal lifted by a manual refresh")
            }
            startCooldown()
            let manualAllowedAt = manualLiveAllowedAt()
            if isOnline,
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
        if isPopoverOpen {
            await scanTranscripts()
        }
    }

    func setPopoverOpen(_ open: Bool) {
        guard open != isPopoverOpen else { return }
        isPopoverOpen = open
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
            self.restartTranscriptLoop()
        }
    }

    private func pauseAll() {
        resumeTask?.cancel()
        cacheTask?.cancel()
        liveTask?.cancel()
        transcriptTask?.cancel()
        resumeTask = nil
        cacheTask = nil
        liveTask = nil
        transcriptTask = nil
        cancelManualLiveFetch()
    }

    private func cancelManualLiveFetch() {
        manualLiveTask?.cancel()
        manualLiveTask = nil
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

    private func restartLiveLoop() {
        liveTask?.cancel()
        liveTask = nil
        guard settings.isLiveModeActive, !isAsleep, isOnline else { return }
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
            let delay = RefreshPlanner.nextCheckDelay(
                freshest: selected,
                now: Date(),
                refreshInterval: cycleInterval,
                nextAllowedLiveAt: liveNotBefore
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

    private enum CacheOutcome: Sendable {
        case unchanged
        case read(FileFingerprint?, UsageSnapshot?)
        case failed(FileFingerprint?, CacheReadError)
    }

    private func checkCache(force: Bool) async {
        let reader = cacheReader
        let previous = cacheFingerprint
        let compare = hasReadCache && !force
        let outcome = await Task.detached(priority: .utility) {
            Self.readCache(reader, previous: previous, compare: compare)
        }.value

        // The config directory may have changed while the read was running.
        guard reader.fileURL == cacheReader.fileURL else { return }

        switch outcome {
        case .unchanged:
            break
        case .read(let fingerprint, let snapshot):
            cacheFingerprint = fingerprint
            hasReadCache = true
            cacheHealth.recordSuccess()
            if candidates.recordCacheRead(snapshot) {
                reselect()
            }
        case .failed(let fingerprint, .accountMismatch):
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
            // Torn reads are expected while Claude Code rewrites the file: keep the previous snapshot and try again
            // when the file changes next. One that lasts is shown (see `CacheReadHealth`).
            cacheFingerprint = fingerprint
            hasReadCache = true
            cacheHealth.recordFailure(error, at: Date())
            cacheLog.notice("Cache read failed (\(error.logName, privacy: .public)); keeping the previous snapshot")
        }
        reportCacheProblem()
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

    // MARK: - Transcripts

    private func scanTranscripts() async {
        guard !isScanningTranscripts else { return }
        isScanningTranscripts = true
        defer { isScanningTranscripts = false }

        let scanner = self.scanner
        let now = Date()
        let sessionResetsAt = selected?.session(at: now)?.resetsAt
        let (activity, daily) = await Task.detached(priority: .utility) {
            let entries = await scanner.scan()
            return Self.aggregate(entries, now: now, sessionResetsAt: sessionResetsAt, calendar: .current)
        }.value

        // Results from a projects directory that is no longer configured are dropped.
        guard scanner === self.scanner else { return }
        onEvent(.activity(activity, daily))
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
            restartLiveLoop()
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
        deletePersistedSnapshot()
        accountGeneration += 1
        paths = ClaudePaths(customConfigDirectory: settings.customConfigDirectory)
        cacheReader = ClaudeCodeCacheReader(fileURL: paths.globalConfigFile)
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
        ]
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
