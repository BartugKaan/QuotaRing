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
///   than the refresh interval, with jitter and back-off from ``RefreshPlanner``.
/// - **Transcripts:** scanned when the popover opens and every 60 s while it stays open.
/// - Pauses on system sleep (and Live while offline), resumes on wake and reconnect.
/// - Persists the last good snapshot (no secrets) and loads it at launch.
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
    }

    var onEvent: (Event) -> Void = { _ in }

    private static let cacheCheckInterval: Duration = .seconds(30)
    private static let transcriptScanInterval: Duration = .seconds(60)

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

    // Candidates for the snapshot on screen.
    private var persisted: UsageSnapshot?
    private var cached: UsageSnapshot?
    private var live: UsageSnapshot?
    private var selected: UsageSnapshot?

    // Live state.
    private var liveStatus: LiveStatus = .off
    private var consecutiveFailures = 0
    private var nextAllowedLiveAt: Date?
    private var lastLiveAttemptAt: Date?
    private var cycleInterval: TimeInterval
    private var isLiveFetchInFlight = false

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

        persisted = snapshotStore?.load()
        if let persisted {
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
            startCooldown()
            let manualAllowedAt = manualLiveAllowedAt()
            if isOnline,
                RefreshPlanner.shouldFetchLive(
                    liveEnabled: true, freshest: nil, now: Date(), refreshInterval: 0,
                    nextAllowedLiveAt: manualAllowedAt)
            {
                await performLiveFetch()
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
                nextAllowedLiveAt: nextAllowedLiveAt
            ) {
                await performLiveFetch()
            }
            guard !Task.isCancelled else { return }
            let delay = RefreshPlanner.nextCheckDelay(
                freshest: selected,
                now: Date(),
                refreshInterval: cycleInterval,
                nextAllowedLiveAt: nextAllowedLiveAt
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
            return
        case .read(let fingerprint, let snapshot):
            cacheFingerprint = fingerprint
            hasReadCache = true
            guard let snapshot else { return }
            if let cached, snapshot.fetchedAt < cached.fetchedAt { return }
            if snapshot != cached {
                cached = snapshot
                reselect()
            }
        case .failed(let fingerprint, let error):
            // Torn reads are expected while Claude Code rewrites the file: keep the previous snapshot and try again
            // when the file changes next.
            cacheFingerprint = fingerprint
            hasReadCache = true
            cacheLog.notice("Cache read failed (\(error.logName, privacy: .public)); keeping the previous snapshot")
        }
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
        return allowed
    }

    private func performLiveFetch() async {
        guard !isLiveFetchInFlight, settings.isLiveModeActive else { return }
        isLiveFetchInFlight = true
        defer { isLiveFetchInFlight = false }

        let started = Date()
        lastLiveAttemptAt = started
        // Keep the loop from re-checking while this request runs; the result sets the real back-off below.
        nextAllowedLiveAt = max(
            nextAllowedLiveAt ?? started, started.addingTimeInterval(RefreshPlanner.minimumLiveSpacing))

        let request = LiveRequest(
            client: UsageAPIClient(transport: transport, userAgent: userAgent),
            paths: paths
        )
        let work = Task.detached(priority: .utility) { await request.run() }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }

        // A request cut off by sleep or by Live mode being turned off says nothing about the server.
        if case .failed(.network) = result, Task.isCancelled { return }
        guard settings.isLiveModeActive else { return }
        apply(result, now: Date())
    }

    private func apply(_ result: LiveFetchResult, now: Date) {
        let policy = PollingPolicy(baseInterval: settings.refreshInterval)
        let retry = RefreshPlanner.retry(
            after: result, consecutiveFailures: consecutiveFailures, policy: policy, random: .random(in: 0...1))
        consecutiveFailures = retry.consecutiveFailures
        nextAllowedLiveAt = now.addingTimeInterval(retry.delay)
        cycleInterval = jitteredInterval()

        if case .snapshot(let snapshot) = result {
            live = snapshot
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
        let freshest = SnapshotSelector.freshest([persisted, cached, live])
        guard freshest != selected else { return }
        selected = freshest
        onEvent(.snapshot(freshest, isNew: true))
        if let freshest, let snapshotStore {
            snapshotStore.save(freshest)
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
            if !appliedLiveActive {
                endCooldown()
            }
            restartLiveLoop()
        }
    }

    /// A different Claude config directory may belong to a different account, so nothing read from the old one is
    /// kept.
    private func switchConfigDirectory() {
        engineLog.info("Claude config directory changed")
        paths = ClaudePaths(customConfigDirectory: settings.customConfigDirectory)
        cacheReader = ClaudeCodeCacheReader(fileURL: paths.globalConfigFile)
        scanner = TranscriptScanner(projectsDirectory: paths.projectsDirectory)
        cacheFingerprint = nil
        hasReadCache = false
        persisted = nil
        cached = nil
        live = nil
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
        monitor.pathUpdateHandler = { [weak self] path in
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

    private static let credentialQueue = DispatchQueue(
        label: "io.github.bartugkaan.QuotaRing.credentials", qos: .utility)

    func run() async -> LiveFetchResult {
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
        let fetcher = LiveUsageFetcher(client: client, credentials: { try credential.get() })
        return await fetcher.fetch()
    }
}

// MARK: - Last snapshot on disk

/// Saves the last good snapshot to `~/Library/Application Support/QuotaRing/last-snapshot.json` so the ring is
/// meaningful right after launch. Only percentages, reset times and the weekly breakdown are written: no token and,
/// for extra usage, no money amounts. The directory is private to the user (0700) and the file is 0600.
struct LastSnapshotStore: Sendable {
    let fileURL: URL

    private static let maxFileSize = 1_048_576
    private static let formatVersion = 1
    private static let writeQueue = DispatchQueue(label: "io.github.bartugkaan.QuotaRing.persistence", qos: .utility)

    private struct Envelope: Codable {
        var version: Int
        var snapshot: UsageSnapshot
    }

    static func standard() -> LastSnapshotStore? {
        guard
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = support.appendingPathComponent("QuotaRing", isDirectory: true)
        return LastSnapshotStore(fileURL: directory.appendingPathComponent("last-snapshot.json", isDirectory: false))
    }

    /// The saved snapshot, or `nil` when there is none or it cannot be used.
    func load() -> UsageSnapshot? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maxFileSize,
            let data = try? Data(contentsOf: fileURL)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.version == Self.formatVersion
        else { return nil }
        return envelope.snapshot
    }

    /// Writes `snapshot` in the background. Saves run one after another, so the newest one wins.
    func save(_ snapshot: UsageSnapshot) {
        guard snapshot.source != .demo else { return }
        let store = self
        Self.writeQueue.async {
            do {
                try store.write(Self.stripped(snapshot))
            } catch {
                persistenceLog.error("Could not save the last snapshot")
            }
        }
    }

    private static func stripped(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var copy = snapshot
        if let extra = copy.report.extraUsage {
            copy.report.extraUsage = ExtraUsage(isEnabled: extra.isEnabled, percentUsed: extra.percentUsed)
        }
        return copy
    }

    private func write(_ snapshot: UsageSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(version: Self.formatVersion, snapshot: snapshot))

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // Write a private temporary file next to the target and rename it over the target: atomic, and the file is
        // never readable by others, not even briefly.
        let temporary = directory.appendingPathComponent(".last-snapshot-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
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
