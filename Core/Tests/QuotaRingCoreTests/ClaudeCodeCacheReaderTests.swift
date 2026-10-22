import Foundation
import Testing

@testable import QuotaRingCore

private let decoy = "sk-test-MUST-NOT-LEAK"
private let fixtureAccountUUID = "00000000-0000-4000-8000-000000000001"

private func fixtureData() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "claude-json-cache", withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A scratch directory removed when the test ends.
private struct Sandbox {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeCodeCacheReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    func write(_ data: Data, named name: String = ".claude.json") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Writes the fixture after letting `edit` change its top-level object.
    @discardableResult
    func writeFixture(named name: String = ".claude.json", edit: (inout [String: Any]) -> Void = { _ in }) throws -> URL
    {
        var root = try #require(try JSONSerialization.jsonObject(with: fixtureData()) as? [String: Any])
        edit(&root)
        return try write(try JSONSerialization.data(withJSONObject: root), named: name)
    }
}

private func edit(_ root: inout [String: Any], cache change: ([String: Any]) -> [String: Any]) {
    root["cachedUsageUtilization"] = change(root["cachedUsageUtilization"] as? [String: Any] ?? [:])
}

@Suite struct ClaudeCodeCacheReaderTests {
    @Test func readsSnapshot() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(fixtureData())

        let snapshot = try #require(try ClaudeCodeCacheReader(fileURL: url).read())

        #expect(snapshot.source == .claudeCodeCache)
        #expect(snapshot.fetchedAt.timeIntervalSince1970 == 1_792_605_287.037)
        #expect(snapshot.report.session?.percentUsed == 4)
        #expect(snapshot.report.limits.count == 3)
        #expect(snapshot.report.weeklyLimits.count == 2)
        #expect(snapshot.report.weeklyBreakdown?.rows.count == 4)
    }

    @Test func missingKeyReturnsNil() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.writeFixture { $0.removeValue(forKey: "cachedUsageUtilization") }

        #expect(try ClaudeCodeCacheReader(fileURL: url).read() == nil)
    }

    @Test func nullKeyReturnsNil() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.writeFixture { $0["cachedUsageUtilization"] = NSNull() }

        #expect(try ClaudeCodeCacheReader(fileURL: url).read() == nil)
    }

    @Test func accountMismatchThrows() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.writeFixture { root in
            root["oauthAccount"] = ["accountUuid": "00000000-0000-4000-8000-0000000000ff"]
        }

        // The cache belongs to another account: the app must drop what it showed, not keep it.
        #expect(throws: CacheReadError.accountMismatch) {
            try ClaudeCodeCacheReader(fileURL: url).read()
        }
    }

    @Test func accountComparisonIgnoresCase() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.writeFixture { root in
            root["oauthAccount"] = ["accountUuid": fixtureAccountUUID.uppercased()]
        }

        #expect(try ClaudeCodeCacheReader(fileURL: url).read() != nil)
    }

    @Test func missingOAuthAccountStillReads() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.writeFixture { $0.removeValue(forKey: "oauthAccount") }

        let snapshot = try #require(try ClaudeCodeCacheReader(fileURL: url).read())
        #expect(snapshot.report.session?.percentUsed == 4)
    }

    @Test func missingCacheAccountStillReads() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.writeFixture { root in
            edit(&root) { cache in
                var cache = cache
                cache.removeValue(forKey: "accountUuid")
                return cache
            }
        }

        #expect(try ClaudeCodeCacheReader(fileURL: url).read() != nil)
    }

    @Test func truncatedFileThrowsMalformed() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let truncated = try fixtureData().prefix(500)
        // The slice must actually contain the decoy, otherwise the leak assertion below proves nothing.
        _ = try #require(truncated.range(of: Data(decoy.utf8)))
        let url = try sandbox.write(truncated)

        do {
            _ = try ClaudeCodeCacheReader(fileURL: url).read()
            Issue.record("expected malformed")
        } catch {
            #expect(error as? CacheReadError == .malformed)
            #expect(!String(reflecting: error).contains(decoy))
        }
    }

    @Test func nonObjectRootThrowsMalformed() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(Data("[1, 2, 3]".utf8))

        #expect(throws: CacheReadError.malformed) {
            try ClaudeCodeCacheReader(fileURL: url).read()
        }
    }

    @Test func wrongShapeThrowsMalformed() throws {
        let bad: [(name: String, value: Any)] = [
            ("not an object", "oops"),
            ("missing fetchedAtMs", ["utilization": [String: Any]()]),
            ("string fetchedAtMs", ["fetchedAtMs": "1792605287037", "utilization": [String: Any]()]),
            ("boolean fetchedAtMs", ["fetchedAtMs": true, "utilization": [String: Any]()]),
            ("missing utilization", ["fetchedAtMs": 1_792_605_287_037]),
            ("null utilization", ["fetchedAtMs": 1_792_605_287_037, "utilization": NSNull()]),
            ("undecodable utilization", ["fetchedAtMs": 1_792_605_287_037, "utilization": ["limits": []]]),
        ]
        for entry in bad {
            let sandbox = try Sandbox()
            defer { sandbox.remove() }
            let url = try sandbox.writeFixture { $0["cachedUsageUtilization"] = entry.value }

            #expect(throws: CacheReadError.malformed, "\(entry.name)") {
                try ClaudeCodeCacheReader(fileURL: url).read()
            }
        }
    }

    @Test func fetchTimeFarInTheFutureThrowsMalformed() throws {
        // The fixture was fetched at 1_792_605_287.037 s. A clock read five minutes or less before that is normal skew.
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(fixtureData())
        let reader = ClaudeCodeCacheReader(fileURL: url)
        let fetchedAt = Date(timeIntervalSince1970: 1_792_605_287.037)

        #expect(try reader.read(now: fetchedAt)?.fetchedAt == fetchedAt)
        #expect(try reader.read(now: fetchedAt.addingTimeInterval(-300)) != nil)
        // Further ahead it would look fresh for that long and block every real update: treated as broken.
        #expect(throws: CacheReadError.malformed) { try reader.read(now: fetchedAt.addingTimeInterval(-301)) }
        #expect(throws: CacheReadError.malformed) { try reader.read(now: fetchedAt.addingTimeInterval(-86_400)) }
    }

    @Test func oversizedFileThrows() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(fixtureData())

        #expect(throws: CacheReadError.fileTooLarge) {
            try ClaudeCodeCacheReader(fileURL: url, maxFileSize: 100).read()
        }
    }

    @Test func fileAtExactlyTheLimitStillReads() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let data = try fixtureData()
        let url = try sandbox.write(data)

        #expect(try ClaudeCodeCacheReader(fileURL: url, maxFileSize: Int64(data.count)).read() != nil)
    }

    @Test func oversizedFileBehindSymlinkThrows() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let target = try sandbox.write(fixtureData(), named: "real.json")
        let link = sandbox.directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // The link's own size is its target path length (about 100 bytes); the limit sits above that and below the
        // fixture's 4662 bytes, so only the size of the resolved target can trip it.
        #expect(throws: CacheReadError.fileTooLarge) {
            try ClaudeCodeCacheReader(fileURL: link, maxFileSize: 1000).read()
        }
        #expect(try ClaudeCodeCacheReader(fileURL: link).read() != nil)
        #expect(ClaudeCodeCacheReader(fileURL: link).fingerprint()?.size == Int64(try fixtureData().count))
    }

    @Test func missingFileFingerprintIsNil() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = sandbox.directory.appendingPathComponent("absent.json")

        #expect(ClaudeCodeCacheReader(fileURL: url).fingerprint() == nil)
    }

    @Test func missingFileReadReturnsNil() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = sandbox.directory.appendingPathComponent("absent.json")

        #expect(try ClaudeCodeCacheReader(fileURL: url).read() == nil)
    }

    @Test func unreadablePathThrowsUnreadable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        // A directory exists and is small but cannot be read as a file.
        let url = sandbox.directory.appendingPathComponent("folder.json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(throws: CacheReadError.unreadable) {
            try ClaudeCodeCacheReader(fileURL: url).read()
        }
    }

    @Test func aFileTheUserCannotReadThrowsUnreadable() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(fixtureData())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }

        // Its size and date can still be seen, so the fingerprint works; reading the bytes is what is refused.
        let reader = ClaudeCodeCacheReader(fileURL: url)
        #expect(reader.fingerprint() != nil)
        #expect(throws: CacheReadError.unreadable) {
            try reader.read()
        }
    }

    @Test func aPathBelowARegularFileIsNoCacheAndNeverASnapshot() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = try sandbox.write(Data("{}".utf8), named: "not-a-folder")
        let url = file.appendingPathComponent(".claude.json")

        // Whatever the system calls it, it must come back as "no cache" or "unreadable", never a crash or a snapshot.
        let reader = ClaudeCodeCacheReader(fileURL: url)
        #expect(reader.fingerprint() == nil)
        do {
            #expect(try reader.read() == nil)
        } catch {
            #expect(error as? CacheReadError == .unreadable)
        }
    }

    @Test func deviceFileThrowsUnreadable() throws {
        // A character device has size 0 (so it passes any size cap) and reads as an empty file.
        #expect(throws: CacheReadError.unreadable) {
            try ClaudeCodeCacheReader(fileURL: URL(fileURLWithPath: "/dev/null")).read()
        }
    }

    @Test func fifoThrowsUnreadableWithoutBlocking() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = sandbox.directory.appendingPathComponent("pipe.json")
        try #require(mkfifo(url.path, 0o600) == 0)
        // Keep a writer open so that a reader that wrongly opens the FIFO can proceed, and close it after a moment
        // so that such a reader sees end-of-file and fails the test instead of hanging the whole run.
        let writer = open(url.path, O_RDWR | O_NONBLOCK)
        try #require(writer >= 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { close(writer) }

        #expect(throws: CacheReadError.unreadable) {
            try ClaudeCodeCacheReader(fileURL: url).read()
        }
    }

    @Test func fingerprintReflectsSizeAndModificationDate() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let data = try fixtureData()
        let url = try sandbox.write(data)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)

        let reader = ClaudeCodeCacheReader(fileURL: url)
        let first = try #require(reader.fingerprint())
        #expect(first == FileFingerprint(size: Int64(data.count), modified: modified))

        try sandbox.write(data + Data("\n".utf8))
        let second = try #require(reader.fingerprint())
        #expect(second != first)
        #expect(second.size == Int64(data.count) + 1)
    }

    @Test func decoyIsNeverSurfaced() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try sandbox.write(fixtureData())
        let reader = ClaudeCodeCacheReader(fileURL: url)

        let snapshot = try #require(try reader.read())
        #expect(!String(reflecting: snapshot).contains(decoy))
        #expect(!String(describing: snapshot).contains(decoy))
        #expect(!String(reflecting: reader).contains(decoy))
        #expect(!String(reflecting: reader.fingerprint()).contains(decoy))
    }

    @Test func decoyIsNeverSurfacedInErrors() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        // The first 500 bytes of the fixture contain the decoy's neighbours; make sure a truncation that includes it
        // still reports only a bare error case.
        let data = try fixtureData()
        let cut = try #require(data.range(of: Data(decoy.utf8))).upperBound + 10
        let url = try sandbox.write(data.prefix(cut))

        do {
            _ = try ClaudeCodeCacheReader(fileURL: url).read()
            Issue.record("expected malformed")
        } catch {
            #expect(error as? CacheReadError == .malformed)
            #expect(!String(reflecting: error).contains(decoy))
            #expect(!error.localizedDescription.contains(decoy))
        }
    }
}
