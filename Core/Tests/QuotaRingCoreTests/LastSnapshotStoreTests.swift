import Foundation
import Testing

@testable import QuotaRingCore

/// A scratch directory removed when the test ends.
private struct Scratch {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LastSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A store whose file sits in a not-yet-existing `QuotaRing` subdirectory, like Application Support.
    var store: LastSnapshotStore {
        LastSnapshotStore(fileURL: directory.appendingPathComponent("QuotaRing/last-snapshot.json"))
    }
}

private let configA = URL(fileURLWithPath: "/Users/test/.claude", isDirectory: true)
private let configB = URL(fileURLWithPath: "/Users/test/work-claude", isDirectory: true)

private func snapshot(source: SnapshotSource = .claudeCodeCache) -> UsageSnapshot {
    UsageSnapshot(
        report: UsageReport(
            limits: [
                UsageLimit(
                    kind: .session, percentUsed: 37.5, resetsAt: Date(timeIntervalSince1970: 1_792_610_000.25)),
                UsageLimit(kind: .weeklyAll, percentUsed: 12, resetsAt: Date(timeIntervalSince1970: 1_793_000_000)),
            ],
            extraUsage: ExtraUsage(
                isEnabled: true, monthlyLimitMinor: 5_000, usedCreditsMinor: 1_234, percentUsed: 24.68,
                currency: "USD", decimalPlaces: 2),
            weeklyBreakdown: WeeklyBreakdown(rows: [BreakdownRow(key: "cowork", displayName: "Cowork", percent: 54)])
        ),
        fetchedAt: Date(timeIntervalSince1970: 1_792_605_287.037),
        source: source
    )
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

@Suite struct LastSnapshotStoreTests {
    @Test func roundTripsForTheSameConfigDirectory() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let original = snapshot(source: .live)

        try scratch.store.save(original, configDirectory: configA)
        let loaded = try #require(scratch.store.load(configDirectory: configA))

        #expect(loaded.fetchedAt == original.fetchedAt)
        #expect(loaded.source == .live)
        #expect(loaded.report.limits == original.report.limits)
        #expect(loaded.report.weeklyBreakdown == original.report.weeklyBreakdown)
    }

    @Test func stripsMoneyAmounts() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }

        try scratch.store.save(snapshot(), configDirectory: configA)
        let extra = try #require(scratch.store.load(configDirectory: configA)?.report.extraUsage)
        #expect(extra == ExtraUsage(isEnabled: true, percentUsed: 24.68))

        let text = try String(contentsOf: scratch.store.fileURL, encoding: .utf8)
        #expect(!text.contains("1234"))
        #expect(!text.contains("5000"))
    }

    @Test func rejectsASnapshotSavedForAnotherConfigDirectory() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }

        try scratch.store.save(snapshot(), configDirectory: configA)

        #expect(scratch.store.load(configDirectory: configB) == nil)
        // Trailing slashes and `..` do not matter: the directory is compared in its standardized form.
        let sameAsA = URL(fileURLWithPath: "/Users/test/x/../.claude/", isDirectory: true)
        #expect(scratch.store.load(configDirectory: sameAsA) != nil)
    }

    @Test func rejectsTheFormerFormatWithoutADirectory() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.store.save(snapshot(), configDirectory: configA)

        // Version 1 had no config directory; it cannot be attributed to an account and is ignored.
        let url = scratch.store.fileURL
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["version"] = 1
        root.removeValue(forKey: "configDirectory")
        try JSONSerialization.data(withJSONObject: root).write(to: url)

        #expect(scratch.store.load(configDirectory: configA) == nil)
    }

    @Test func deleteRemovesTheFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        try scratch.store.save(snapshot(), configDirectory: configA)

        try scratch.store.delete()

        #expect(!FileManager.default.fileExists(atPath: scratch.store.fileURL.path))
        #expect(scratch.store.load(configDirectory: configA) == nil)
        // Deleting what is not there is fine.
        try scratch.store.delete()
    }

    @Test func writesPrivateDirectoryAndFile() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let directory = scratch.store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        try scratch.store.save(snapshot(), configDirectory: configA)

        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: scratch.store.fileURL) == 0o600)
        // No temporary files are left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["last-snapshot.json"])
    }

    @Test func demoSnapshotsAreNeverSaved() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }

        try scratch.store.save(snapshot(source: .demo), configDirectory: configA)

        #expect(!FileManager.default.fileExists(atPath: scratch.store.fileURL.path))
    }

    @Test func ignoresUnusableFiles() throws {
        let scratch = try Scratch()
        defer { scratch.remove() }
        let store = scratch.store
        let directory = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Missing.
        #expect(store.load(configDirectory: configA) == nil)

        // Garbage.
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load(configDirectory: configA) == nil)

        // Larger than 1 MB.
        try Data(repeating: 0x20, count: 1_048_577).write(to: store.fileURL)
        #expect(store.load(configDirectory: configA) == nil)

        // A symbolic link, even to a valid file.
        try FileManager.default.removeItem(at: store.fileURL)
        let real = LastSnapshotStore(fileURL: scratch.directory.appendingPathComponent("real.json"))
        try real.save(snapshot(), configDirectory: configA)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: real.fileURL)
        #expect(real.load(configDirectory: configA) != nil)
        #expect(store.load(configDirectory: configA) == nil)
    }
}
