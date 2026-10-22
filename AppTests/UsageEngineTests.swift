import Foundation
import QuotaRingCore
import Security
import Testing

/// Tests of ``UsageEngine``'s cache and transcript handling.
///
/// What is safe to run here, and why: the engine is built on a settings store whose Claude config directory is a folder
/// of the test, with a snapshot store in another folder of the test, and with Live mode and auto-refresh off (they need
/// a completed welcome window, which a test never records). So `refresh` and `setPopoverOpen` only read files below
/// the test's folder and write there. `start()` is never called: it looks for the real `claude` tool, starts the
/// network monitor and observes the system. The Live request (Keychain, network) and the auto-refresh run (a real
/// program) have no seam, so they are not covered here.
@MainActor
private final class EngineRig {
    let sandbox: TestSandbox
    let settings: SettingsStore
    let configDirectory: URL
    let store: LastSnapshotStore
    let engine: UsageEngine
    /// The fakes behind Live mode and auto-refresh. The engine reaches nothing real through them.
    let credentials = FakeCredentialReader()
    let transport = FakeTransport()
    let cli = FakeCLIRunner()
    private(set) var events: [UsageEngine.Event] = []

    var cacheFile: URL { configDirectory.appendingPathComponent(".claude.json") }

    /// - Parameters:
    ///   - live: Turns Live mode on, the way the welcome window does. Its credential read, request and the rest go to
    ///     the fakes above: no Keychain, no network.
    ///   - autoRefresh: Turns auto-refresh on. Its runs go to the fake runner: no Claude Code is started.
    init(live: Bool = false, autoRefresh: Bool = false) throws {
        sandbox = try TestSandbox()
        configDirectory = try sandbox.claudeConfigDirectory()
        settings = sandbox.makeSettings()
        settings.customConfigDirectory = configDirectory
        // Nothing may run or reach out unless the test asks for it, and then only the fakes can be reached.
        try #require(!settings.isLiveModeActive && !settings.isCLIRefreshActive)
        if live {
            settings.liveModeEnabled = true
            settings.hasCompletedOnboarding = true
        }
        if autoRefresh {
            settings.cliRefreshEnabled = true
            settings.hasCompletedOnboarding = true
        }
        store = LastSnapshotStore(fileURL: sandbox.directory.appendingPathComponent("store/last-snapshot.json"))
        engine = UsageEngine(
            settings: settings, snapshotStore: store, transport: transport, liveCredentials: credentials.reader,
            cliRefresher: cli)
        engine.onEvent = { [weak self] event in self?.events.append(event) }
    }

    // MARK: Events

    /// Every snapshot the engine announced, in order (`nil` for "nothing to show any more").
    var snapshots: [UsageSnapshot?] {
        events.compactMap { event in
            if case .snapshot(let snapshot, _) = event { return .some(snapshot) }
            return nil
        }
    }

    var liveStatuses: [LiveStatus] {
        events.compactMap { event in
            if case .liveStatus(let status) = event { return status }
            return nil
        }
    }

    var cacheProblems: [CacheReadError?] {
        events.compactMap { event in
            if case .cacheProblem(let problem) = event { return .some(problem) }
            return nil
        }
    }

    var activities: [[ActivityRange: UsageBreakdown]] {
        events.compactMap { event in
            if case .activity(let activity, _) = event { return activity }
            return nil
        }
    }

    var refreshingFlags: [Bool] {
        events.compactMap { event in
            if case .refreshing(let flag) = event { return flag }
            return nil
        }
    }

    /// Events that only Live mode or auto-refresh produce.
    var consentRelatedEvents: Int {
        events.filter { event in
            switch event {
            case .liveStatus, .coolingDown, .cliStatus, .cliBinary: true
            default: false
            }
        }.count
    }

    // MARK: Files

    func writeCache(
        fetchedAt: Date, sessionUsed: Double, resetsAt: Date, cacheAccount: String = TestAccounts.a,
        signedInAccount: String = TestAccounts.a
    ) throws {
        try sandbox.writeClaudeJSON(
            in: configDirectory, fetchedAt: fetchedAt, sessionUsed: sessionUsed, resetsAt: resetsAt,
            cacheAccount: cacheAccount, signedInAccount: signedInAccount)
    }

    func writeTranscript(at timestamp: Date, input: Int, output: Int, project: String = "alpha") throws {
        try sandbox.writeTranscript(
            in: configDirectory, at: timestamp, input: input, output: output, project: project)
    }

    /// Waits until the background saves and deletes of the snapshot have caught up with the last announced snapshot,
    /// so that none of them lands after the test's folder is gone.
    func settle() async {
        guard case .some(let last) = snapshots.last else { return }
        if let last {
            _ = await eventually { self.store.load(configDirectory: self.configDirectory) == last }
        } else {
            _ = await eventually { !FileManager.default.fileExists(atPath: self.store.fileURL.path) }
        }
    }

    func finish() async {
        await settle()
        sandbox.remove()
    }
}

@MainActor
@Suite struct UsageEngineCacheTests {
    private let now = Date()

    @Test func aGoodCacheBecomesTheSnapshot() async throws {
        let rig = try EngineRig()
        let fetchedAt = now.addingTimeInterval(-30)
        let resetsAt = now.addingTimeInterval(7_200)
        try rig.writeCache(fetchedAt: fetchedAt, sessionUsed: 42.5, resetsAt: resetsAt)

        await rig.engine.refresh(userInitiated: false)

        let announced = try #require(rig.snapshots.first ?? nil)
        #expect(rig.snapshots.count == 1)
        #expect(announced.source == .claudeCodeCache)
        #expect(announced.report.session?.percentUsed == 42.5)
        #expect(announced.report.weeklyLimits.count == 1)
        #expect(abs(announced.fetchedAt.timeIntervalSince(fetchedAt)) < 0.01)
        #expect(abs(try #require(announced.report.session?.resetsAt).timeIntervalSince(resetsAt)) < 0.01)
        // A new reading, not the one loaded from disk at launch.
        let isNew = rig.events.contains { event in
            if case .snapshot(_, let isNew) = event { return isNew }
            return false
        }
        #expect(isNew)
        await rig.finish()
    }

    @Test func aRefreshReportsItselfAsRunningAndThenAsDone() async throws {
        let rig = try EngineRig()
        try rig.writeCache(fetchedAt: now, sessionUsed: 10, resetsAt: now.addingTimeInterval(3_600))

        await rig.engine.refresh(userInitiated: false)

        #expect(rig.refreshingFlags == [true, false])
        guard case .refreshing(true) = rig.events.first else {
            Issue.record("the first event was not refreshing(true)")
            return
        }
        guard case .refreshing(false) = rig.events.last else {
            Issue.record("the last event was not refreshing(false)")
            return
        }
        await rig.finish()
    }

    @Test func theSnapshotIsSavedForTheNextLaunchWithoutAnythingSecret() async throws {
        let rig = try EngineRig()
        try rig.writeCache(
            fetchedAt: now.addingTimeInterval(-5), sessionUsed: 61, resetsAt: now.addingTimeInterval(900))

        await rig.engine.refresh(userInitiated: false)
        let announced = try #require(rig.snapshots.first ?? nil)

        #expect(await eventually { rig.store.load(configDirectory: rig.configDirectory) == announced })
        // Bound to the config directory it was read from: another directory gets nothing.
        let other = try rig.sandbox.folder("another-config")
        #expect(rig.store.load(configDirectory: other) == nil)
        await rig.finish()
    }

    @Test func aMissingCacheIsNoSnapshotAndNoProblem() async throws {
        let rig = try EngineRig()

        await rig.engine.refresh(userInitiated: false)

        #expect(rig.snapshots.isEmpty)
        #expect(rig.cacheProblems.isEmpty)
        #expect(rig.refreshingFlags == [true, false])
        #expect(!FileManager.default.fileExists(atPath: rig.store.fileURL.path))
        await rig.finish()
    }

    @Test func aCacheWithoutAUsageEntryIsNoSnapshot() async throws {
        let rig = try EngineRig()
        try rig.sandbox.write("claude-config/.claude.json", "{\"numStartups\": 3}")

        await rig.engine.refresh(userInitiated: false)

        #expect(rig.snapshots.isEmpty)
        #expect(rig.cacheProblems.isEmpty)
        await rig.finish()
    }

    @Test func aHalfWrittenFileKeepsThePreviousSnapshotOnScreen() async throws {
        let rig = try EngineRig()
        try rig.writeCache(
            fetchedAt: now.addingTimeInterval(-10), sessionUsed: 33, resetsAt: now.addingTimeInterval(3_000))
        await rig.engine.refresh(userInitiated: false)
        try #require(rig.snapshots.count == 1)

        // Claude Code is in the middle of rewriting the file.
        try rig.sandbox.write("claude-config/.claude.json", "{\"cachedUsageUtilization\": {\"fetchedAtM")
        await rig.engine.refresh(userInitiated: false)

        // No "nothing to show", no new snapshot; and one torn read is not yet a problem worth showing.
        #expect(rig.snapshots.count == 1)
        #expect(rig.cacheProblems.isEmpty)
        await rig.finish()
    }

    @Test func aFileThatCannotBeUsedIsReportedAtOnceAndClearedOnceItWorks() async throws {
        let rig = try EngineRig()
        // A folder where the file belongs: it exists, but cannot be read as a file.
        try FileManager.default.createDirectory(at: rig.cacheFile, withIntermediateDirectories: true)

        await rig.engine.refresh(userInitiated: false)

        #expect(rig.cacheProblems == [.unreadable])
        #expect(rig.snapshots.isEmpty)

        try FileManager.default.removeItem(at: rig.cacheFile)
        try rig.writeCache(fetchedAt: now, sessionUsed: 5, resetsAt: now.addingTimeInterval(1_000))
        await rig.engine.refresh(userInitiated: false)

        #expect(rig.cacheProblems == [.unreadable, nil])
        #expect(rig.snapshots.count == 1)
        await rig.finish()
    }

    @Test func aNewerReadingReplacesTheOldOneAndAnOlderOneDoesNot() async throws {
        let rig = try EngineRig()
        let reset = now.addingTimeInterval(4_000)
        try rig.writeCache(fetchedAt: now.addingTimeInterval(-100), sessionUsed: 20, resetsAt: reset)
        await rig.engine.refresh(userInitiated: false)

        try rig.writeCache(fetchedAt: now.addingTimeInterval(-50), sessionUsed: 25, resetsAt: reset)
        await rig.engine.refresh(userInitiated: false)
        #expect(rig.snapshots.compactMap { $0?.report.session?.percentUsed } == [20, 25])

        // A read that is older than the one held (an out-of-order read) is ignored.
        try rig.writeCache(fetchedAt: now.addingTimeInterval(-500), sessionUsed: 90, resetsAt: reset)
        await rig.engine.refresh(userInitiated: false)
        #expect(rig.snapshots.compactMap { $0?.report.session?.percentUsed } == [20, 25])
        await rig.finish()
    }

    @Test func anIdenticalReadingIsNotAnnouncedAgain() async throws {
        let rig = try EngineRig()
        try rig.writeCache(
            fetchedAt: now.addingTimeInterval(-10), sessionUsed: 20, resetsAt: now.addingTimeInterval(4_000))

        await rig.engine.refresh(userInitiated: false)
        await rig.engine.refresh(userInitiated: false)
        await rig.engine.refresh(userInitiated: false)

        #expect(rig.snapshots.count == 1)
        await rig.finish()
    }

    @Test func aCacheOfAnotherAccountDropsEverythingReadSoFarFromScreenAndDisk() async throws {
        let rig = try EngineRig()
        try rig.writeCache(
            fetchedAt: now.addingTimeInterval(-10), sessionUsed: 70, resetsAt: now.addingTimeInterval(3_000))
        await rig.engine.refresh(userInitiated: false)
        try #require(rig.snapshots.count == 1)
        try #require(await eventually { rig.store.load(configDirectory: rig.configDirectory) != nil })

        // The signed-in account changed; the cache still holds the previous account's numbers.
        try rig.writeCache(
            fetchedAt: now.addingTimeInterval(-5), sessionUsed: 71, resetsAt: now.addingTimeInterval(3_000),
            cacheAccount: TestAccounts.a, signedInAccount: TestAccounts.b)
        await rig.engine.refresh(userInitiated: false)

        // Announced as "nothing to show", as a new state, and removed from disk.
        #expect(rig.snapshots.count == 2)
        #expect(rig.snapshots.last! == nil)
        #expect(await eventually { !FileManager.default.fileExists(atPath: rig.store.fileURL.path) })
        // It is not a read problem to tell the user about.
        #expect(rig.cacheProblems.isEmpty)

        // Reading the same mismatch again announces nothing more.
        await rig.engine.refresh(userInitiated: false)
        #expect(rig.snapshots.count == 2)

        // Once the cache is the signed-in account's again, its numbers show.
        try rig.writeCache(
            fetchedAt: now, sessionUsed: 3, resetsAt: now.addingTimeInterval(3_000),
            cacheAccount: TestAccounts.b, signedInAccount: TestAccounts.b)
        await rig.engine.refresh(userInitiated: false)
        #expect(rig.snapshots.last??.report.session?.percentUsed == 3)
        await rig.finish()
    }

    @Test func withConsentOffARefreshNeverTouchesLiveModeOrAutoRefresh() async throws {
        let rig = try EngineRig()
        try rig.writeCache(fetchedAt: now, sessionUsed: 12, resetsAt: now.addingTimeInterval(1_000))

        await rig.engine.refresh(userInitiated: true)
        await rig.engine.refresh(userInitiated: true)

        // No cooldown (that is Live mode's and auto-refresh's), no status of either, no tool lookup.
        #expect(rig.consentRelatedEvents == 0)
        #expect(rig.snapshots.count == 1)
        await rig.finish()
    }

    @Test func switchingTheLiveHoldOnAndOffChangesNothingWhileLiveModeIsOff() async throws {
        let rig = try EngineRig()

        rig.engine.holdLiveRequests(until: now.addingTimeInterval(15))
        rig.engine.releaseLiveHold()
        rig.engine.releaseLiveHold()
        await rig.engine.refresh(userInitiated: true)

        #expect(rig.consentRelatedEvents == 0)
        await rig.finish()
    }
}

@MainActor
@Suite struct UsageEngineTranscriptTests {
    private let now = Date()

    /// A moment shortly before `now` that is still today, whatever the time of day.
    private var recent: Date {
        let sinceMidnight = now.timeIntervalSince(Calendar.current.startOfDay(for: now))
        return now.addingTimeInterval(-min(30, sinceMidnight / 2))
    }

    @Test func transcriptsAreNotReadWhileThePopoverIsClosed() async throws {
        let rig = try EngineRig()
        try rig.writeTranscript(at: recent, input: 1_000, output: 500)

        await rig.engine.refresh(userInitiated: false)

        #expect(rig.activities.isEmpty)
        await rig.finish()
    }

    @Test func openingThePopoverTotalsTheTranscriptsForEveryRange() async throws {
        let rig = try EngineRig()
        try rig.writeTranscript(at: recent, input: 1_000, output: 500)

        rig.engine.setPopoverOpen(true)
        defer { rig.engine.setPopoverOpen(false) }

        #expect(await eventually { !rig.activities.isEmpty })
        let activity = try #require(rig.activities.first)
        for range in ActivityRange.allCases {
            let breakdown = try #require(activity[range], "\(range) is missing")
            #expect(breakdown.total.input == 1_000)
            #expect(breakdown.total.output == 500)
            #expect(breakdown.byProject.map(\.name) == ["alpha"])
        }
        // The daily totals come with it: seven days, today last.
        let dailyCounts = rig.events.compactMap { event -> Int? in
            if case .activity(_, let daily) = event { return daily.count }
            return nil
        }
        #expect(dailyCounts.first == 7)
        await rig.finish()
    }

    @Test func aRefreshWithThePopoverOpenScansAgain() async throws {
        let rig = try EngineRig()
        rig.engine.setPopoverOpen(true)
        defer { rig.engine.setPopoverOpen(false) }
        try #require(await eventually { !rig.activities.isEmpty })
        let before = rig.activities.count
        #expect(rig.activities.first?[.today]?.total.total == 0)

        try rig.writeTranscript(at: recent, input: 200, output: 100)
        await rig.engine.refresh(userInitiated: false)

        #expect(rig.activities.count > before)
        #expect(rig.activities.last?[.today]?.total.total == 300)
        await rig.finish()
    }

    @Test func closingThePopoverStopsTheScans() async throws {
        let rig = try EngineRig()
        rig.engine.setPopoverOpen(true)
        try #require(await eventually { !rig.activities.isEmpty })
        rig.engine.setPopoverOpen(false)
        let scansWhileOpen = rig.activities.count
        try rig.writeTranscript(at: recent, input: 50, output: 50)

        await rig.engine.refresh(userInitiated: false)
        try await Task.sleep(for: .milliseconds(100))

        #expect(rig.activities.count == scansWhileOpen)
        await rig.finish()
    }

    @Test func openingTheSamePopoverTwiceDoesNotScanTwice() async throws {
        let rig = try EngineRig()
        rig.engine.setPopoverOpen(true)
        rig.engine.setPopoverOpen(true)
        rig.engine.setPopoverOpen(true)
        defer { rig.engine.setPopoverOpen(false) }

        try #require(await eventually { !rig.activities.isEmpty })
        try await Task.sleep(for: .milliseconds(100))

        #expect(rig.activities.count == 1)
        await rig.finish()
    }

    @Test func transcriptsOutsideTheConfigDirectoryAreNeverRead() async throws {
        let rig = try EngineRig()
        // A transcript below the sandbox but not below the configured directory's `projects` folder.
        try rig.sandbox.write("elsewhere/projects/-p/other.jsonl", "{}\n")
        rig.engine.setPopoverOpen(true)
        defer { rig.engine.setPopoverOpen(false) }

        try #require(await eventually { !rig.activities.isEmpty })

        #expect(rig.activities.first?[.week]?.total.total == 0)
        await rig.finish()
    }
}

/// Whether the engine knows that nobody can look at the numbers. What it does about it (pausing the Live and
/// auto-refresh loops, starting them again with a check of what is due) has no seam without a real Keychain and a real
/// program, so these tests cover the state: what sends the user away, what brings them back, and that the local cache
/// check does not depend on it.
@MainActor
@Suite struct UsageEnginePresenceTests {
    private let now = Date()

    @Test func theUserIsPresentAtTheStart() throws {
        let rig = try EngineRig()
        #expect(!rig.engine.isUserAway)
        rig.sandbox.remove()
    }

    @Test(arguments: [
        UserPresence.Signal.displaysSlept, .sessionResigned, .screenLocked,
    ])
    func eachWayOfBeingAwayIsNoticed(signal: UserPresence.Signal) throws {
        let rig = try EngineRig()
        rig.engine.presenceDidChange(signal)
        #expect(rig.engine.isUserAway)
        rig.sandbox.remove()
    }

    @Test func theUserIsBackWhenEveryConditionHasEnded() throws {
        let rig = try EngineRig()
        rig.engine.presenceDidChange(.screenLocked)
        rig.engine.presenceDidChange(.displaysSlept)
        rig.engine.presenceDidChange(.displaysWoke)
        #expect(rig.engine.isUserAway)

        rig.engine.presenceDidChange(.screenUnlocked)

        #expect(!rig.engine.isUserAway)
        rig.sandbox.remove()
    }

    @Test func openingThePopoverMeansTheUserIsThere() throws {
        let rig = try EngineRig()
        rig.engine.presenceDidChange(.screenLocked)

        rig.engine.setPopoverOpen(true)
        rig.engine.setPopoverOpen(false)

        #expect(!rig.engine.isUserAway)
        rig.sandbox.remove()
    }

    @Test func pressingRefreshMeansTheUserIsThere() async throws {
        let rig = try EngineRig()
        rig.engine.presenceDidChange(.displaysSlept)

        await rig.engine.refresh(userInitiated: true)

        #expect(!rig.engine.isUserAway)
        await rig.finish()
    }

    @Test func aRefreshNobodyAskedForDoesNotMeanTheUserIsThere() async throws {
        let rig = try EngineRig()
        rig.engine.presenceDidChange(.displaysSlept)

        await rig.engine.refresh(userInitiated: false)

        #expect(rig.engine.isUserAway)
        await rig.finish()
    }

    @Test func aRefreshReadsTheCacheEvenWhileNobodyIsLooking() async throws {
        let rig = try EngineRig()
        rig.engine.presenceDidChange(.screenLocked)
        try rig.writeCache(
            fetchedAt: now.addingTimeInterval(-20), sessionUsed: 47, resetsAt: now.addingTimeInterval(3_600))

        await rig.engine.refresh(userInitiated: false)

        let announced = try #require(rig.snapshots.first ?? nil)
        #expect(announced.report.session?.percentUsed == 47)
        await rig.finish()
    }
}

/// The engine's loops while it runs (started without listening to the system), with Live mode and auto-refresh behind
/// fakes: nothing here reads the Keychain, reaches the network or starts Claude Code.
@MainActor
@Suite struct UsageEngineLoopTests {
    private func stop(_ rig: EngineRig) async {
        rig.engine.shutDown()
        await rig.finish()
    }

    // MARK: Presence

    @Test func theLoopsDoNotStartWhileNobodyIsLookingAndStartWhenSomebodyIsBack() async throws {
        let rig = try EngineRig(live: true, autoRefresh: true)
        rig.engine.presenceDidChange(.screenLocked)

        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.engine.isCacheLoopRunning })
        // The loops that ask Anthropic or run Claude Code stay off, and nothing is asked or run.
        #expect(!rig.engine.isLiveLoopRunning)
        #expect(!rig.engine.isCLILoopRunning)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.credentials.reads == 0)
        #expect(rig.cli.runs == 0)

        rig.engine.presenceDidChange(.screenUnlocked)

        // Back: they start, and each looks at once at what is due (no snapshot, so both are).
        #expect(await eventually { rig.engine.isLiveLoopRunning && rig.engine.isCLILoopRunning })
        #expect(await eventually { rig.credentials.reads == 1 && rig.cli.runs == 1 })
        await stop(rig)
    }

    @Test func goingAwayStopsTheLoopsThatAskAndLeavesTheCacheCheckRunning() async throws {
        let rig = try EngineRig(live: true, autoRefresh: true)
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.engine.isLiveLoopRunning && rig.engine.isCLILoopRunning })
        let starts = rig.engine.loopStarts

        rig.engine.presenceDidChange(.displaysSlept)

        #expect(!rig.engine.isLiveLoopRunning)
        #expect(!rig.engine.isCLILoopRunning)
        #expect(rig.engine.isCacheLoopRunning)
        #expect(rig.engine.loopStarts == starts)
        await stop(rig)
    }

    @Test func comingBackStartsTheLoopsAgain() async throws {
        let rig = try EngineRig(live: true, autoRefresh: true)
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.engine.isLiveLoopRunning && rig.engine.isCLILoopRunning })
        rig.engine.presenceDidChange(.sessionResigned)
        try #require(!rig.engine.isLiveLoopRunning)
        let before = rig.engine.loopStarts

        rig.engine.presenceDidChange(.sessionBecameActive)

        #expect(await eventually { rig.engine.loopStarts.live == before.live + 1 })
        #expect(rig.engine.loopStarts.cli == before.cli + 1)
        #expect(rig.engine.isLiveLoopRunning && rig.engine.isCLILoopRunning)
        await stop(rig)
    }

    // MARK: A Keychain refusal

    @Test func aRefusalGivenAfterTheLoopWasCancelledStillSuspendsLive() async throws {
        let rig = try EngineRig(live: true)
        rig.credentials.answer(with: .failure(.keychain(errSecUserCanceled)))
        rig.credentials.holdNextRead()
        // A failing check must not leave the shared credential queue blocked for the tests after this one.
        defer { rig.credentials.releaseHeldRead() }
        rig.engine.start(observingSystem: false)
        // The loop asks for the credential and the Keychain prompt stays open.
        try #require(await eventually { rig.credentials.reads == 1 })

        // The screen locks, so the loop and with it the request waiting for the prompt are cancelled; the user comes
        // back, and only then clicks "Deny".
        rig.engine.presenceDidChange(.screenLocked)
        rig.engine.presenceDidChange(.screenUnlocked)
        try #require(await eventually { rig.engine.isLiveLoopRunning })
        #expect(!rig.engine.isLiveRequestsSuspended)
        rig.credentials.releaseHeldRead()

        #expect(await eventually { rig.engine.isLiveRequestsSuspended })
        #expect(rig.liveStatuses.last == .keychainDenied)
        // Nothing was sent, and the new loop does not show the prompt again.
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.transport.requests == 0)
        #expect(rig.credentials.reads == 1)
        await stop(rig)
    }

    @Test func aRefusalIsNotAppliedWhenLiveModeWasTurnedOffMeanwhile() async throws {
        let rig = try EngineRig(live: true)
        rig.credentials.answer(with: .failure(.keychain(errSecUserCanceled)))
        rig.credentials.holdNextRead()
        // A failing check must not leave the shared credential queue blocked for the tests after this one.
        defer { rig.credentials.releaseHeldRead() }
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.credentials.reads == 1 })

        rig.settings.liveModeEnabled = false
        rig.engine.presenceDidChange(.screenLocked)
        rig.credentials.releaseHeldRead()

        // The answer was to a request that no longer applies.
        try await Task.sleep(for: .milliseconds(150))
        #expect(!rig.engine.isLiveRequestsSuspended)
        #expect(!rig.liveStatuses.contains(.keychainDenied))
        await stop(rig)
    }

    @Test func aCredentialGrantedAfterTheLoopWasCancelledSendsNothing() async throws {
        let rig = try EngineRig(live: true)
        rig.credentials.answer(
            with: .success(OAuthCredential(accessToken: Secret("not-a-real-token"), expiresAt: nil)))
        rig.credentials.holdNextRead()
        // A failing check must not leave the shared credential queue blocked for the tests after this one.
        defer { rig.credentials.releaseHeldRead() }
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.credentials.reads == 1 })

        rig.engine.presenceDidChange(.screenLocked)
        rig.credentials.releaseHeldRead()

        // "Allow" came too late: the request was cancelled, so it is not sent.
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.transport.requests == 0)
        #expect(!rig.engine.isLiveRequestsSuspended)
        await stop(rig)
    }

    @Test func aSuspendedLiveLoopStartsAgainWhenRefreshLiftsTheSuspension() async throws {
        let rig = try EngineRig(live: true)
        rig.credentials.answer(with: .failure(.keychain(errSecUserCanceled)))
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.engine.isLiveRequestsSuspended })
        #expect(rig.engine.loopStarts.live == 1)
        // The loop sleeps for the longest wait; nothing but the user wakes it.
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.credentials.reads == 1)

        // The user presses Refresh, and this time the read fails for another reason (no credential at all).
        rig.credentials.answer(with: .failure(.notFound))
        await rig.engine.refresh(userInitiated: true)

        #expect(rig.credentials.reads == 2)
        #expect(!rig.engine.isLiveRequestsSuspended)
        #expect(rig.liveStatuses.last == .noCredential)
        #expect(rig.engine.loopStarts.live == 2)
        #expect(rig.engine.isLiveLoopRunning)
        await stop(rig)
    }

    @Test func aRefreshThatLiftsNothingLeavesTheLiveLoopAlone() async throws {
        let rig = try EngineRig(live: true)
        rig.credentials.answer(with: .failure(.notFound))
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.credentials.reads == 1 })
        try #require(await eventually { rig.liveStatuses.last == .noCredential })

        await rig.engine.refresh(userInitiated: true)

        #expect(rig.engine.loopStarts.live == 1)
        await stop(rig)
    }

    @Test func aRefusedRefreshSuspendsLiveAgainAndKeepsTheLoopAsleep() async throws {
        let rig = try EngineRig(live: true)
        rig.credentials.answer(with: .failure(.keychain(errSecAuthFailed)))
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.engine.isLiveRequestsSuspended })

        await rig.engine.refresh(userInitiated: true)

        // The user refused again: suspended, and the restarted loop does not ask a third time.
        #expect(rig.engine.isLiveRequestsSuspended)
        #expect(rig.engine.loopStarts.live == 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.credentials.reads == 2)
        await stop(rig)
    }
}

/// The transcript scan and its loop. The scan is slow enough to catch under way because the fixture holds several
/// megabytes of transcript lines.
@MainActor
@Suite struct UsageEngineScanTests {
    private let now = Date()

    /// Writes a transcript of `lines` distinct responses from the last minute, about 400 bytes each.
    private func writeBigTranscript(into rig: EngineRig, lines: Int) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: now.addingTimeInterval(-30))
        var text = ""
        text.reserveCapacity(lines * 420)
        for index in 0..<lines {
            text +=
                "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"cwd\":\"/Users/test/dev/alpha\","
                + "\"requestId\":\"req_BIG\(index)\",\"message\":{\"id\":\"msg_BIG\(index)\",\"role\":\"assistant\","
                + "\"model\":\"claude-opus-4-8\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
                + "\"usage\":{\"input_tokens\":1,\"output_tokens\":2,\"cache_creation_input_tokens\":0,"
                + "\"cache_read_input_tokens\":0}}}\n"
        }
        try rig.sandbox.write("claude-config/projects/-p/big.jsonl", text)
    }

    @Test func closingThePopoverCancelsTheScanUnderWayAndDropsItsResult() async throws {
        let rig = try EngineRig()
        try writeBigTranscript(into: rig, lines: 30_000)

        rig.engine.setPopoverOpen(true)
        try #require(await eventually { rig.engine.isScanningTranscripts })
        rig.engine.setPopoverOpen(false)

        #expect(!rig.engine.isScanningTranscripts)
        // The scan would have finished long before this; it was stopped, and what it had found was not announced.
        try await Task.sleep(for: .seconds(2))
        #expect(rig.activities.isEmpty)
        await rig.finish()
    }

    @Test func aScanThatWasStoppedIsContinuedByTheNextOneAndFindsEverything() async throws {
        let rig = try EngineRig()
        try writeBigTranscript(into: rig, lines: 30_000)
        rig.engine.setPopoverOpen(true)
        try #require(await eventually { rig.engine.isScanningTranscripts })
        rig.engine.setPopoverOpen(false)

        rig.engine.setPopoverOpen(true)
        defer { rig.engine.setPopoverOpen(false) }

        #expect(await eventually { !rig.activities.isEmpty })
        #expect(rig.activities.last?[.week]?.total.input == 30_000)
        await rig.finish()
    }

    @Test func restartingTheLoopDuringAScanDoesNotLoseTheScan() async throws {
        let rig = try EngineRig()
        try writeBigTranscript(into: rig, lines: 30_000)
        rig.engine.setPopoverOpen(true)
        defer { rig.engine.setPopoverOpen(false) }
        try #require(await eventually { rig.engine.isScanningTranscripts })

        // What a new config directory or a wake does while the popover stays open.
        rig.engine.restartTranscriptLoop()

        // The new loop scans at once; it is not turned away by the old scan, whose result is dropped.
        #expect(await eventually { !rig.activities.isEmpty })
        #expect(rig.activities.last?[.week]?.total.input == 30_000)
        #expect(rig.engine.loopStarts.transcripts == 2)
        await rig.finish()
    }

    @Test func comingBackLeavesARunningTranscriptLoopAndItsScanAlone() async throws {
        let rig = try EngineRig(live: true)
        try writeBigTranscript(into: rig, lines: 30_000)
        rig.engine.start(observingSystem: false)
        try #require(await eventually { rig.engine.isLiveLoopRunning })
        rig.engine.setPopoverOpen(true)
        try #require(await eventually { rig.engine.isScanningTranscripts })
        let before = rig.engine.loopStarts

        // Presence never pauses the transcript loop, so returning must not restart it (which would cancel the scan).
        rig.engine.presenceDidChange(.screenLocked)
        rig.engine.presenceDidChange(.screenUnlocked)
        try #require(await eventually { rig.engine.loopStarts.live == before.live + 1 })

        #expect(rig.engine.loopStarts.transcripts == before.transcripts)
        #expect(await eventually { !rig.activities.isEmpty })
        #expect(rig.activities.last?[.week]?.total.input == 30_000)
        rig.engine.setPopoverOpen(false)
        rig.engine.shutDown()
        await rig.finish()
    }
}
