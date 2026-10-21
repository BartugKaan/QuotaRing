import Foundation
import Observation
import QuotaRingCore
import os

/// The time ranges of the local activity breakdown.
enum ActivityRange: String, CaseIterable, Identifiable {
    /// The current 5-hour session window (or the last 5 hours when its start is unknown).
    case session
    /// Since local midnight.
    case today
    /// The last 7 local days, including today.
    case week

    var id: String { rawValue }
}

/// Receives threshold events worth telling the user about (installed by the notification service).
@MainActor protocol UsageNotifier: AnyObject {
    func post(_ events: [ThresholdEvent], snapshot: UsageSnapshot)
}

/// The app's observable state. Views and the status item render from it; ``UsageEngine`` feeds it.
@MainActor @Observable
final class AppModel {
    let settings: SettingsStore

    /// The snapshot on screen: the freshest of the persisted, cached and live ones. Never replaced by nothing
    /// because a read failed.
    private(set) var snapshot: UsageSnapshot?
    private(set) var liveStatus: LiveStatus = .off
    /// Whether a manual refresh is in progress.
    private(set) var isRefreshing = false
    /// Local token totals per range; filled while the popover is open.
    private(set) var activity: [ActivityRange: UsageBreakdown] = [:]
    /// Token totals for the last 7 local days, oldest first.
    private(set) var daily: [DailyTokens] = []
    /// Whether the app runs on built-in fixture data (`--demo`): no Keychain, no network, no file access.
    private(set) var isDemo: Bool
    /// Whether the manual refresh cooldown (Live mode only) is running.
    private(set) var isCoolingDown = false
    /// Why Claude Code's cache file cannot be used right now, if it exists but cannot be read for a while.
    private(set) var cacheProblem: CacheReadError?

    /// Gets threshold events after each new snapshot.
    @ObservationIgnored var notifier: (any UsageNotifier)?

    /// Whether the Refresh button should be enabled.
    var canRefreshNow: Bool {
        !isRefreshing && !isCoolingDown
    }

    @ObservationIgnored private var engine: UsageEngine?
    @ObservationIgnored private var thresholdTracker: ThresholdTracker
    @ObservationIgnored private let defaults: UserDefaults

    init(settings: SettingsStore, isDemo: Bool, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.isDemo = isDemo
        self.defaults = defaults
        thresholdTracker = Self.loadThresholdTracker(from: defaults, enabled: !isDemo)

        if isDemo {
            let now = Date()
            snapshot = DemoData.snapshot(now: now)
            activity = DemoData.activity(now: now)
            daily = DemoData.daily(now: now, calendar: .current)
        } else {
            let engine = UsageEngine(settings: settings)
            engine.onEvent = { [weak self] event in self?.handle(event) }
            self.engine = engine
        }
    }

    /// Starts reading data. Call once, after the notifier is installed.
    func start() {
        engine?.start()
    }

    /// The session limit as it applies at `now` (shown as reset once its reset time has passed).
    func session(at now: Date) -> UsageLimit? {
        snapshot?.session(at: now)
    }

    /// Whether the snapshot is old enough to be shown as stale: more than two refresh intervals.
    func isStale(at now: Date) -> Bool {
        guard let snapshot, !isDemo else { return false }
        return snapshot.isStale(at: now, maxAge: 2 * settings.refreshInterval)
    }

    /// Re-reads Claude Code's cache; with `userInitiated` in Live mode, also asks the endpoint (at most once a
    /// minute, never with an expired token).
    func refresh(userInitiated: Bool) async {
        await engine?.refresh(userInitiated: userInitiated)
    }

    func popoverDidOpen() {
        engine?.setPopoverOpen(true)
    }

    func popoverDidClose() {
        engine?.setPopoverOpen(false)
    }

    /// Called as time passes (every 30 s): announces a session reset as soon as its time has come, without waiting
    /// for new data, which may arrive much later (with the cache alone, not until Claude Code runs again).
    func timeDidPass(now: Date = Date()) {
        guard !isDemo, snapshot != nil else { return }
        var tracker = thresholdTracker
        let events = tracker.observeWindowEnd(now: now)
        post(events, tracker: tracker)
    }

    /// Makes Live mode's first Keychain read wait until `deadline` (or ``releaseLiveRequests()``), so that macOS's
    /// Keychain prompt does not appear while another system prompt is open.
    func holdLiveRequests(until deadline: Date) {
        engine?.holdLiveRequests(until: deadline)
    }

    func releaseLiveRequests() {
        engine?.releaseLiveHold()
    }

    // MARK: - Engine events

    private func handle(_ event: UsageEngine.Event) {
        switch event {
        case .snapshot(let newSnapshot, let isNew):
            snapshot = newSnapshot
            if isNew, let newSnapshot {
                evaluateThresholds(for: newSnapshot)
            }
        case .liveStatus(let status):
            liveStatus = status
        case .refreshing(let refreshing):
            isRefreshing = refreshing
        case .coolingDown(let coolingDown):
            isCoolingDown = coolingDown
        case .activity(let newActivity, let newDaily):
            activity = newActivity
            daily = newDaily
        case .cacheProblem(let problem):
            cacheProblem = problem
        }
    }

    private func evaluateThresholds(for snapshot: UsageSnapshot) {
        let now = Date()
        guard let session = snapshot.session(at: now) else { return }
        var tracker = thresholdTracker
        let events = tracker.observe(
            percentUsed: session.percentUsed,
            resetsAt: session.resetsAt,
            thresholds: settings.notificationThresholds,
            now: now
        )
        post(events, tracker: tracker)
    }

    /// Saves `tracker` if it changed and hands the events the user wants to the notifier.
    private func post(_ events: [ThresholdEvent], tracker: ThresholdTracker) {
        if tracker != thresholdTracker {
            thresholdTracker = tracker
            saveThresholdTracker()
        }
        var events = events
        if !settings.notifyOnReset {
            events.removeAll { $0 == .reset }
        }
        if !events.isEmpty, let snapshot {
            notifier?.post(events, snapshot: snapshot)
        }
    }

    // MARK: - Threshold tracker persistence

    private static let thresholdTrackerKey = "thresholdTracker"

    private static func loadThresholdTracker(from defaults: UserDefaults, enabled: Bool) -> ThresholdTracker {
        guard enabled, let data = defaults.data(forKey: thresholdTrackerKey),
            let tracker = try? JSONDecoder().decode(ThresholdTracker.self, from: data)
        else { return ThresholdTracker() }
        return tracker
    }

    private func saveThresholdTracker() {
        guard !isDemo, let data = try? JSONEncoder().encode(thresholdTracker) else { return }
        defaults.set(data, forKey: Self.thresholdTrackerKey)
    }
}

extension AppModel: LiveRequestGate {}

extension LiveStatus {
    /// A short, non-sensitive name for logs.
    var logName: String {
        switch self {
        case .off: "off"
        case .ok: "ok"
        case .expired: "expired"
        case .noCredential: "noCredential"
        case .keychainDenied: "keychainDenied"
        case .rateLimited: "rateLimited"
        case .error: "error"
        }
    }
}
