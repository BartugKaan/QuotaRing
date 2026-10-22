import Foundation
import QuotaRingCore
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
    static let accountA = "00000000-0000-4000-8000-0000000000a1"
    static let accountB = "00000000-0000-4000-8000-0000000000b2"

    let sandbox: TestSandbox
    let settings: SettingsStore
    let configDirectory: URL
    let store: LastSnapshotStore
    let engine: UsageEngine
    private(set) var events: [UsageEngine.Event] = []

    var cacheFile: URL { configDirectory.appendingPathComponent(".claude.json") }

    init() throws {
        sandbox = try TestSandbox()
        configDirectory = try sandbox.folder("claude-config")
        settings = sandbox.makeSettings()
        settings.customConfigDirectory = configDirectory
        // Nothing may run or reach out: consent is off.
        try #require(!settings.isLiveModeActive && !settings.isCLIRefreshActive)
        store = LastSnapshotStore(fileURL: sandbox.directory.appendingPathComponent("store/last-snapshot.json"))
        engine = UsageEngine(settings: settings, snapshotStore: store)
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

    /// Writes Claude Code's `.claude.json` with a session limit.
    func writeCache(
        fetchedAt: Date, sessionUsed: Double, resetsAt: Date, cacheAccount: String = accountA,
        signedInAccount: String = accountA
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root: [String: Any] = [
            "oauthAccount": ["accountUuid": signedInAccount],
            "cachedUsageUtilization": [
                "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
                "accountUuid": cacheAccount,
                "utilization": [
                    "five_hour": ["utilization": sessionUsed, "resets_at": formatter.string(from: resetsAt)],
                    "seven_day": [
                        "utilization": 18.0, "resets_at": formatter.string(from: resetsAt.addingTimeInterval(86_400)),
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root).write(to: cacheFile)
    }

    /// One assistant line of a transcript, written below the config directory's `projects` folder.
    func writeTranscript(at timestamp: Date, input: Int, output: Int, project: String = "alpha") throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line =
            "{\"type\":\"assistant\",\"timestamp\":\"\(formatter.string(from: timestamp))\","
            + "\"cwd\":\"/Users/test/dev/\(project)\",\"requestId\":\"req_TEST1\",\"message\":{\"id\":\"msg_TEST1\","
            + "\"role\":\"assistant\",\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":\(input),"
            + "\"output_tokens\":\(output),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n"
        try sandbox.write("claude-config/projects/-p/session.jsonl", line)
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
            cacheAccount: EngineRig.accountA, signedInAccount: EngineRig.accountB)
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
            cacheAccount: EngineRig.accountB, signedInAccount: EngineRig.accountB)
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
