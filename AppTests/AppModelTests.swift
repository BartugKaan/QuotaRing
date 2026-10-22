import Foundation
import QuotaRingCore
import Testing

/// An ``AppModel`` that cannot reach anything real: its settings and defaults are the sandbox's, the engine behind it
/// (when it is not a demo model) looks at a Claude config directory inside the sandbox and saves its snapshot there,
/// and `start()` is never called.
@MainActor
final class ModelRig {
    let sandbox: TestSandbox
    let settings: SettingsStore
    let configDirectory: URL
    let storeFile: URL
    let notifier = RecordingNotifier()
    let model: AppModel

    init(demo: Bool = false) throws {
        sandbox = try TestSandbox()
        configDirectory = try sandbox.claudeConfigDirectory()
        storeFile = sandbox.directory.appendingPathComponent("store/last-snapshot.json")
        settings = sandbox.makeSettings()
        // Before the model exists: the engine takes its paths from the settings when it is built.
        settings.customConfigDirectory = configDirectory
        model = AppModel(
            settings: settings, isDemo: demo, defaults: sandbox.defaults,
            snapshotStore: LastSnapshotStore(fileURL: storeFile))
        model.notifier = notifier
    }

    /// Another model on the same preferences, as after a relaunch.
    func relaunchedModel() -> AppModel {
        let model = AppModel(
            settings: settings, isDemo: false, defaults: sandbox.defaults,
            snapshotStore: LastSnapshotStore(fileURL: storeFile))
        model.notifier = notifier
        return model
    }

    /// Turns Live mode on the way the welcome window does.
    func enableLiveMode() {
        settings.liveModeEnabled = true
        settings.hasCompletedOnboarding = true
    }

    /// Lets the engine's background save of a snapshot finish, so that none lands after the sandbox is gone.
    func finish() async {
        if model.snapshot != nil, !model.isDemo {
            _ = await eventually { FileManager.default.fileExists(atPath: self.storeFile.path) }
        }
        sandbox.remove()
    }

    var savedTracker: Data? { sandbox.defaults.data(forKey: "thresholdTracker") }
}

@MainActor
@Suite struct AppModelDemoTests {
    @Test func aDemoModelStartsWithTheFixtureData() throws {
        let rig = try ModelRig(demo: true)
        defer { rig.sandbox.remove() }

        #expect(rig.model.isDemo)
        #expect(rig.model.snapshot?.source == .demo)
        #expect(rig.model.snapshot?.report.session?.percentUsed == 28)
        #expect(Set(rig.model.activity.keys) == Set(ActivityRange.allCases))
        #expect(rig.model.daily.count == 7)
        #expect(rig.model.liveStatus == .off)
        #expect(rig.model.cliStatus == .off)
        #expect(rig.model.cliBinary == nil)
        #expect(rig.model.cacheProblem == nil)
        #expect(rig.model.canRefreshNow)
        #expect(rig.model.settingsTab == .general)
    }

    @Test func demoNumbersAreNeverStale() throws {
        let rig = try ModelRig(demo: true)
        defer { rig.sandbox.remove() }

        // However late it is, the screenshot data does not turn dashed.
        #expect(!rig.model.isStale(at: Date()))
        #expect(!rig.model.isStale(at: Date().addingTimeInterval(30 * 86_400)))
    }

    @Test func aDemoModelNeverAnnouncesTheEndOfASessionOrSavesAThresholdState() throws {
        let rig = try ModelRig(demo: true)
        defer { rig.sandbox.remove() }
        rig.settings.notifyOnReset = true

        // Long after the demo session's reset time.
        rig.model.timeDidPass(now: Date().addingTimeInterval(10 * 86_400))
        // Even an event fed in by hand leaves nothing in the saved preferences.
        rig.model.handle(.snapshot(TestData.snapshot(now: Date(), sessionUsed: 99), isNew: true))

        #expect(rig.notifier.allEvents.contains(.reset) == false)
        #expect(rig.savedTracker == nil)
    }

    @Test func aDemoModelIgnoresTheControlCallsThatNeedAnEngine() async throws {
        let rig = try ModelRig(demo: true)
        defer { rig.sandbox.remove() }
        let before = rig.model.snapshot

        rig.model.start()
        await rig.model.refresh(userInitiated: true)
        rig.model.inspectCLI()
        rig.model.popoverDidOpen()
        rig.model.popoverDidClose()
        rig.model.holdLiveRequests(until: Date().addingTimeInterval(15))
        rig.model.releaseLiveRequests()
        rig.model.shutDown()

        #expect(rig.model.snapshot == before)
        #expect(!rig.model.isRefreshing)
        #expect(rig.model.cliBinary == nil)
        // The demo activity is still on screen: no transcript was read.
        #expect(rig.model.activity[.today]?.total.total ?? 0 > 0)
    }
}

@MainActor
@Suite struct AppModelStateTests {
    private let now = Date()

    @Test func aFreshModelHasNothingToShow() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        #expect(!rig.model.isDemo)
        #expect(rig.model.snapshot == nil)
        #expect(rig.model.session(at: now) == nil)
        #expect(!rig.model.isStale(at: now))
        #expect(rig.model.activity.isEmpty)
        #expect(rig.model.daily.isEmpty)
        #expect(rig.model.liveStatus == .off)
        #expect(rig.model.cliStatus == .off)
        #expect(rig.model.cacheProblem == nil)
        #expect(rig.model.canRefreshNow)
    }

    // MARK: canRefreshNow

    @Test func refreshIsOfferedUnlessOneIsRunningOrCoolingDown() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        rig.model.handle(.refreshing(true))
        #expect(rig.model.isRefreshing)
        #expect(!rig.model.canRefreshNow)

        rig.model.handle(.coolingDown(true))
        #expect(!rig.model.canRefreshNow)

        rig.model.handle(.refreshing(false))
        // Still cooling down after the refresh itself ended.
        #expect(!rig.model.isRefreshing)
        #expect(rig.model.isCoolingDown)
        #expect(!rig.model.canRefreshNow)

        rig.model.handle(.coolingDown(false))
        #expect(rig.model.canRefreshNow)
    }

    // MARK: session(at:) and isStale(at:)

    @Test func theSessionIsShownAsResetOnceItsTimeHasPassed() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let snapshot = TestData.snapshot(now: now, sessionUsed: 70, resetsIn: 600)
        rig.model.handle(.snapshot(snapshot, isNew: false))

        let before = try #require(rig.model.session(at: now))
        #expect(before.percentUsed == 70)
        #expect(before.resetsAt == now.addingTimeInterval(600))

        let after = try #require(rig.model.session(at: now.addingTimeInterval(601)))
        #expect(after.percentUsed == 0)
        #expect(after.resetsAt == nil)
        #expect(after.percentRemaining == 100)
    }

    @Test func aSnapshotWithoutASessionLimitHasNoSession() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.model.handle(.snapshot(TestData.snapshotWithoutSession(now: now), isNew: false))

        #expect(rig.model.snapshot != nil)
        #expect(rig.model.session(at: now) == nil)
    }

    @Test func numbersAreStaleAfterMoreThanTwoRefreshIntervals() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        // The default interval is 5 minutes, so 10 minutes.
        rig.model.handle(.snapshot(TestData.snapshot(now: now, fetchedAgo: 0), isNew: false))

        #expect(!rig.model.isStale(at: now))
        #expect(!rig.model.isStale(at: now.addingTimeInterval(599)))
        #expect(!rig.model.isStale(at: now.addingTimeInterval(600)))
        #expect(rig.model.isStale(at: now.addingTimeInterval(601)))
        #expect(rig.model.isStale(at: now.addingTimeInterval(86_400)))
    }

    @Test func theStaleLimitFollowsTheRefreshInterval() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.model.handle(.snapshot(TestData.snapshot(now: now, fetchedAgo: 0), isNew: false))

        rig.settings.refreshInterval = 900
        #expect(!rig.model.isStale(at: now.addingTimeInterval(1_800)))
        #expect(rig.model.isStale(at: now.addingTimeInterval(1_801)))

        rig.settings.refreshInterval = 180
        #expect(!rig.model.isStale(at: now.addingTimeInterval(360)))
        #expect(rig.model.isStale(at: now.addingTimeInterval(361)))
    }

    @Test func aSnapshotDatedInTheFutureIsNotStale() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.model.handle(.snapshot(TestData.snapshot(now: now, fetchedAgo: -120), isNew: false))

        #expect(!rig.model.isStale(at: now))
    }

    // MARK: Events

    @Test func eachEngineEventIsStored() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let breakdown = UsageBreakdown(total: TokenCounts(input: 5), byModel: [], byProject: [])
        let day = DailyTokens(day: now, tokens: TokenCounts(output: 3))
        let binary = CLIBinaryState(
            location: CLILocation(executable: nil, customPathProblem: .missing), versionCheck: nil)

        rig.model.handle(.liveStatus(.expired))
        rig.model.handle(.cliStatus(.notLoggedIn))
        rig.model.handle(.cacheProblem(.unreadable))
        rig.model.handle(.activity([.today: breakdown], [day]))
        rig.model.handle(.cliBinary(binary))

        #expect(rig.model.liveStatus == .expired)
        #expect(rig.model.cliStatus == .notLoggedIn)
        #expect(rig.model.cacheProblem == .unreadable)
        #expect(rig.model.activity == [.today: breakdown])
        #expect(rig.model.daily == [day])
        #expect(rig.model.cliBinary == binary)

        rig.model.handle(.cacheProblem(nil))
        #expect(rig.model.cacheProblem == nil)
    }

    @Test func aReadFailureNeverReplacesTheSnapshotByNothing() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let snapshot = TestData.snapshot(now: now)
        rig.model.handle(.snapshot(snapshot, isNew: true))

        // A cache problem is reported on the side; the numbers stay.
        rig.model.handle(.cacheProblem(.malformed))

        #expect(rig.model.snapshot == snapshot)
    }

    @Test func anExplicitNothingToShowClearsTheSnapshot() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.model.handle(.snapshot(TestData.snapshot(now: now), isNew: true))

        // What the engine sends when the signed-in account changed.
        rig.model.handle(.snapshot(nil, isNew: true))

        #expect(rig.model.snapshot == nil)
        #expect(rig.model.session(at: now) == nil)
    }
}

@MainActor
@Suite struct AppModelNotificationTests {
    private let now = Date()

    @Test func aNewReadingOverAThresholdIsAnnouncedOnce() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let hot = TestData.snapshot(now: now, sessionUsed: 85, resetsIn: 3_000)

        rig.model.handle(.snapshot(hot, isNew: true))
        #expect(rig.notifier.posts == [[.crossed(80)]])

        // The same window, the same threshold: nothing more, also after a new reading.
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 86, resetsIn: 3_000), isNew: true))
        #expect(rig.notifier.posts == [[.crossed(80)]])

        // A higher one is a new event.
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 96, resetsIn: 3_000), isNew: true))
        #expect(rig.notifier.posts == [[.crossed(80)], [.crossed(95)]])
    }

    @Test func bothThresholdsCrossedAtOnceComeTogetherInOrder() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 99, resetsIn: 3_000), isNew: true))

        #expect(rig.notifier.posts == [[.crossed(80), .crossed(95)]])
    }

    @Test func aSnapshotLoadedFromDiskNeverNotifies() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 99, resetsIn: 3_000), isNew: false))

        #expect(rig.notifier.posts.isEmpty)
        #expect(rig.savedTracker == nil)
    }

    @Test func belowEveryThresholdNothingIsAnnounced() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 79.9, resetsIn: 3_000), isNew: true))

        #expect(rig.notifier.posts.isEmpty)
    }

    @Test func theUsersThresholdsDecideWhatIsAnnounced() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.settings.notificationThresholds = [50]

        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 60, resetsIn: 3_000), isNew: true))
        #expect(rig.notifier.posts == [[.crossed(50)]])

        let silent = try ModelRig()
        defer { silent.sandbox.remove() }
        silent.settings.notificationThresholds = []
        silent.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 99, resetsIn: 3_000), isNew: true))
        #expect(silent.notifier.posts.isEmpty)
    }

    @Test func aSnapshotWhoseSessionAlreadyResetAnnouncesNothing() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        // 99 percent of a window that is already over is not 99 percent of the current one.
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 99, resetsIn: -60), isNew: true))

        #expect(rig.notifier.posts.isEmpty)
    }

    @Test func aSnapshotWithoutASessionAnnouncesNothing() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        rig.model.handle(.snapshot(TestData.snapshotWithoutSession(now: now), isNew: true))

        #expect(rig.notifier.posts.isEmpty)
    }

    // MARK: Time passing

    @Test func aSessionResetIsAnnouncedAsSoonAsItsTimeComesWhenTheUserWantsIt() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.settings.notifyOnReset = true
        let resetsAt = now.addingTimeInterval(3_000)
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 10, resetsIn: 3_000), isNew: true))
        try #require(rig.notifier.posts.isEmpty)

        rig.model.timeDidPass(now: resetsAt.addingTimeInterval(-60))
        #expect(rig.notifier.posts.isEmpty)

        rig.model.timeDidPass(now: resetsAt.addingTimeInterval(60))
        #expect(rig.notifier.posts == [[.reset]])

        // Once only.
        rig.model.timeDidPass(now: resetsAt.addingTimeInterval(90))
        #expect(rig.notifier.posts == [[.reset]])
    }

    @Test func aResetIsNotAnnouncedWhenTheUserDidNotAskForIt() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        #expect(!rig.settings.notifyOnReset)
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 10, resetsIn: 3_000), isNew: true))
        let before = rig.savedTracker

        rig.model.timeDidPass(now: now.addingTimeInterval(4_000))

        #expect(rig.notifier.posts.isEmpty)
        // The window is still closed in the saved state, so the reset is not announced later either.
        #expect(rig.savedTracker != before)
        rig.settings.notifyOnReset = true
        rig.model.timeDidPass(now: now.addingTimeInterval(5_000))
        #expect(rig.notifier.posts.isEmpty)
    }

    @Test func aNewWindowAfterAResetAnnouncesItsThresholdsAgain() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 90, resetsIn: 600), isNew: true))
        try #require(rig.notifier.posts == [[.crossed(80)]])
        rig.model.timeDidPass(now: now.addingTimeInterval(700))

        // The next window: the same percentage is news again.
        rig.model.handle(
            .snapshot(
                TestData.snapshot(now: now.addingTimeInterval(800), sessionUsed: 90, resetsIn: 18_000), isNew: true))

        #expect(rig.notifier.allEvents.filter { $0 == .crossed(80) }.count == 2)
    }

    @Test func timePassingWithoutASnapshotDoesNothing() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.settings.notifyOnReset = true

        rig.model.timeDidPass(now: now.addingTimeInterval(86_400))

        #expect(rig.notifier.posts.isEmpty)
        #expect(rig.savedTracker == nil)
    }

    // MARK: Saved state

    @Test func theAnnouncedThresholdsAreRememberedAcrossARelaunch() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        let hot = TestData.snapshot(now: now, sessionUsed: 85, resetsIn: 3_000)
        rig.model.handle(.snapshot(hot, isNew: true))
        try #require(rig.notifier.posts == [[.crossed(80)]])
        try #require(rig.savedTracker != nil)

        let relaunched = rig.relaunchedModel()
        relaunched.handle(.snapshot(hot, isNew: true))

        // Not announced a second time just because the app restarted in the same window.
        #expect(rig.notifier.posts == [[.crossed(80)]])
    }

    @Test func aDamagedSavedStateStartsFresh() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }
        rig.sandbox.defaults.set(Data("not json".utf8), forKey: "thresholdTracker")

        let model = rig.relaunchedModel()
        model.handle(.snapshot(TestData.snapshot(now: now, sessionUsed: 85, resetsIn: 3_000), isNew: true))

        #expect(rig.notifier.posts == [[.crossed(80)]])
    }
}

@MainActor
@Suite struct AppModelEngineTests {
    private let now = Date()

    @Test func refreshingReadsClaudeCodesCacheIntoTheSnapshotAndNotifies() async throws {
        let rig = try ModelRig()
        try rig.sandbox.writeClaudeJSON(
            in: rig.configDirectory, fetchedAt: now.addingTimeInterval(-20), sessionUsed: 91,
            resetsAt: now.addingTimeInterval(5_000))

        await rig.model.refresh(userInitiated: false)

        #expect(rig.model.snapshot?.report.session?.percentUsed == 91)
        #expect(rig.model.snapshot?.source == .claudeCodeCache)
        #expect(!rig.model.isRefreshing)
        #expect(rig.model.canRefreshNow)
        #expect(rig.notifier.posts == [[.crossed(80)]])
        #expect(rig.model.liveStatus == .off)
        await rig.finish()
    }

    @Test func aManualRefreshWithoutConsentStartsNoCooldown() async throws {
        let rig = try ModelRig()

        await rig.model.refresh(userInitiated: true)

        #expect(!rig.model.isCoolingDown)
        #expect(rig.model.canRefreshNow)
        await rig.finish()
    }

    @Test func aCacheThatCannotBeReadIsReportedAndTheOldNumbersStay() async throws {
        let rig = try ModelRig()
        try rig.sandbox.writeClaudeJSON(
            in: rig.configDirectory, fetchedAt: now.addingTimeInterval(-20), sessionUsed: 30,
            resetsAt: now.addingTimeInterval(5_000))
        await rig.model.refresh(userInitiated: false)
        let shown = rig.model.snapshot
        try #require(shown != nil)

        let cache = rig.configDirectory.appendingPathComponent(".claude.json")
        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        await rig.model.refresh(userInitiated: false)

        #expect(rig.model.cacheProblem == .unreadable)
        #expect(rig.model.snapshot == shown)
        await rig.finish()
    }

    @Test func openingAndClosingThePopoverStartsAndStopsReadingTranscripts() async throws {
        let rig = try ModelRig()
        try rig.sandbox.writeTranscript(
            in: rig.configDirectory, at: now.addingTimeInterval(-5), input: 40, output: 2)
        // The transcript is stamped a few seconds ago, which is "today" unless it is just after midnight.
        let sinceMidnight = now.timeIntervalSince(Calendar.current.startOfDay(for: now))
        try #require(sinceMidnight > 60)

        rig.model.popoverDidOpen()
        #expect(await eventually { rig.model.activity[.session]?.total.total == 42 })
        #expect(rig.model.daily.count == 7)
        rig.model.popoverDidClose()

        // Closed: later changes are not picked up until it opens again.
        try rig.sandbox.writeTranscript(
            in: rig.configDirectory, at: now.addingTimeInterval(-4), input: 400, output: 20)
        await rig.model.refresh(userInitiated: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.model.activity[.session]?.total.total == 42)
        await rig.finish()
    }

    @Test func theSettingsTabCanBeChosenByThePopover() throws {
        let rig = try ModelRig()
        defer { rig.sandbox.remove() }

        rig.model.settingsTab = .data

        #expect(rig.model.settingsTab == .data)
    }
}
