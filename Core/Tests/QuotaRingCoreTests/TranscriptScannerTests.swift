import Foundation
import Testing

@testable import QuotaRingCore

// MARK: - Helpers

/// A scratch directory; the owning suite removes it when the test finishes.
private final class ScratchDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaRingTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relativePath: String) -> URL {
        url.appendingPathComponent(relativePath, isDirectory: false)
    }

    /// Writes `lines` (each terminated by a newline) to `relativePath`, creating directories as needed.
    @discardableResult
    func write(_ relativePath: String, lines: [String]) throws -> URL {
        try write(relativePath, text: lines.map { $0 + "\n" }.joined())
    }

    @discardableResult
    func write(_ relativePath: String, text: String) throws -> URL {
        let target = file(relativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }

    func append(_ text: String, to relativePath: String) throws {
        let handle = try FileHandle(forWritingTo: file(relativePath))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func modificationDate(of url: URL) throws -> Date {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// Stands in for `Task.isCancelled`: answers `false` for the first `allowedChecks` questions and `true` after that, so
/// that a test can cancel a scan at an exact point. The scan asks once per directory it lists, once per file and
/// once before every chunk it reads.
private final class CancelAfter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int

    init(allowedChecks: Int) {
        remaining = allowedChecks
    }

    /// Sets how many further questions are answered with `false`; `.max` stops cancelling.
    func allow(_ checks: Int) {
        lock.lock()
        remaining = checks
        lock.unlock()
    }

    func check() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { return true }
        remaining -= 1
        return false
    }
}

private func seconds(_ text: String) throws -> Date {
    try #require(FlexibleDate.parse(text))
}

/// 2026-10-21T12:00:00Z: the clock of every scan, so the 8-day retention keeps the fixture lines (dated 2026-10-20)
/// whenever the tests run.
private let scanNow = Date(timeIntervalSince1970: 1_792_584_000)

// MARK: - Tests

@Suite final class TranscriptScannerTests {
    private let scratch: ScratchDirectory

    init() throws {
        scratch = try ScratchDirectory()
    }

    deinit {
        scratch.remove()
    }

    // MARK: Dedupe

    @Test func dedupesContentBlockLines() async throws {
        // One streamed message written once per content block; the output count grows as the stream goes on.
        try scratch.write(
            "-Users-test-dev-alpha/s1.jsonl",
            lines: [
                assistantLine(output: 11, timestamp: "2026-10-20T20:35:00.527Z"),
                assistantLine(output: 11, timestamp: "2026-10-20T20:35:02.001Z"),
                assistantLine(output: 302, timestamp: "2026-10-20T20:35:04.310Z"),
            ])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.tokens == TokenCounts(input: 7021, output: 302, cacheWrite: 17371, cacheRead: 0))
        #expect(entry.timestamp == (try seconds("2026-10-20T20:35:00.527Z")))
        #expect(entry.project == "alpha")
    }

    @Test func dedupesAcrossSubagentFiles() async throws {
        try scratch.write("-Users-test-dev-alpha/s1.jsonl", lines: [assistantLine()])
        try scratch.write(
            "-Users-test-dev-alpha/s1/subagents/agent-x.jsonl",
            lines: [
                assistantLine(),
                assistantLine(id: "msg_01TESTSUBONLY", requestId: "req_01TESTSUBONLY", input: 5, output: 6),
            ])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(entries.count == 2)
        #expect(
            Set(entries.map(\.dedupeKey)) == [
                "msg_01TESTAAAAAAAAAAAAAAAAA1|req_01TESTAAAAAAAAAAAAAAAAA1",
                "msg_01TESTSUBONLY|req_01TESTSUBONLY",
            ])
        let parent = try #require(entries.first { $0.dedupeKey.hasPrefix("msg_01TESTAAAA") })
        #expect(parent.tokens.total == 24_694)
    }

    @Test func scansTheFixtureTree() async throws {
        let fixtures = try #require(
            Bundle.module.url(forResource: "transcripts", withExtension: nil, subdirectory: "Fixtures"))
        let projects = scratch.file("projects")
        try FileManager.default.copyItem(at: fixtures, to: projects)

        let entries = await TranscriptScanner(projectsDirectory: projects).scan(now: scanNow)

        // The opus message appears as three content blocks in the session file and once more in the subagent file;
        // user, tool_result, <synthetic> and truncated lines contribute nothing.
        #expect(entries.count == 3)
        #expect(entries.map(\.model) == ["claude-opus-4-8", "claude-sonnet-4-5-20250929", "claude-haiku-4-5-20251001"])
        #expect(entries.map(\.project) == ["alpha", "alpha", "alpha"])
        #expect(
            entries.map(\.tokens) == [
                TokenCounts(input: 7021, output: 302, cacheWrite: 17371, cacheRead: 0),
                TokenCounts(input: 300, output: 80, cacheWrite: 0, cacheRead: 1500),
                TokenCounts(input: 120, output: 45, cacheWrite: 0, cacheRead: 2000),
            ])
        #expect(entries.first?.timestamp == (try seconds("2026-10-20T20:35:00.527Z")))
        #expect(entries == entries.sorted { $0.timestamp < $1.timestamp })
    }

    @Test func keepsFieldwiseMax() async throws {
        // Same message seen in two files, each holding a different partial view of the usage.
        try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(
                    input: 10, output: 5, cacheWrite: 0, cacheRead: 100,
                    timestamp: "2026-10-20T10:00:05.000Z", cwd: nil)
            ])
        try scratch.write(
            "-p/b.jsonl",
            lines: [
                assistantLine(
                    input: 12, output: 3, cacheWrite: 7, cacheRead: 90,
                    timestamp: "2026-10-20T10:00:01.000Z", cwd: "/Users/test/dev/beta")
            ])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        let entry = try #require(entries.first)
        #expect(entries.count == 1)
        #expect(entry.tokens == TokenCounts(input: 12, output: 5, cacheWrite: 7, cacheRead: 100))
        #expect(entry.timestamp == (try seconds("2026-10-20T10:00:01.000Z")))
        // The first file has no cwd (project "Unknown"), so the first known project wins.
        #expect(entry.project == "beta")
    }

    @Test func laterAppendsRaiseTheMaxAndNeverLowerIt() async throws {
        try scratch.write("-p/a.jsonl", lines: [assistantLine(output: 50)])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).first?.tokens.output == 50)

        try scratch.append(assistantLine(output: 400) + "\n", to: "-p/a.jsonl")
        #expect(await scanner.scan(now: scanNow).first?.tokens.output == 400)

        try scratch.append(assistantLine(output: 20) + "\n", to: "-p/a.jsonl")
        let entries = await scanner.scan(now: scanNow)
        #expect(entries.count == 1)
        #expect(entries.first?.tokens.output == 400)
    }

    // MARK: Incremental reads

    @Test func readsOnlyAppendedBytes() async throws {
        let url = try scratch.write(
            "-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTONE", input: 1111)])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).first?.tokens.input == 1111)

        // Rewrite already-scanned bytes in place (same length), then append a new record. An incremental scanner
        // has already consumed the old bytes, so it keeps what it saw and parses only the new line.
        let original = try String(contentsOf: url, encoding: .utf8)
        let tampered = original.replacingOccurrences(of: "\"input_tokens\":1111", with: "\"input_tokens\":2222")
        #expect(tampered.utf8.count == original.utf8.count)
        try Data(tampered.utf8).write(to: url, options: [])
        try scratch.append(assistantLine(id: "msg_01TESTTWO", input: 3333) + "\n", to: "-p/a.jsonl")

        let entries = await scanner.scan(now: scanNow)
        #expect(entries.count == 2)
        #expect(entries.first { $0.dedupeKey.hasPrefix("msg_01TESTONE") }?.tokens.input == 1111)
        #expect(entries.first { $0.dedupeKey.hasPrefix("msg_01TESTTWO") }?.tokens.input == 3333)
    }

    @Test func partialTrailingLineIsDeferred() async throws {
        let first = assistantLine(id: "msg_01TESTFIRST", timestamp: "2026-10-20T10:00:00Z")
        let second = assistantLine(id: "msg_01TESTSECOND", timestamp: "2026-10-20T10:01:00Z")
        let splitAt = second.index(second.startIndex, offsetBy: second.count / 2)
        try scratch.write("-p/a.jsonl", text: first + "\n" + String(second[..<splitAt]))
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        // Half a record is not counted (and not counted wrongly).
        let partial = await scanner.scan(now: scanNow)
        #expect(partial.map(\.dedupeKey) == ["msg_01TESTFIRST|req_01TESTAAAAAAAAAAAAAAAAA1"])

        // Nothing new yet: still deferred.
        #expect(await scanner.scan(now: scanNow).count == 1)

        // The rest of the line arrives (with its newline) and the record is counted exactly once.
        try scratch.append(String(second[splitAt...]) + "\n", to: "-p/a.jsonl")
        let complete = await scanner.scan(now: scanNow)
        #expect(complete.count == 2)
        #expect(complete.map(\.dedupeKey).filter { $0.hasPrefix("msg_01TESTSECOND") }.count == 1)
        #expect(await scanner.scan(now: scanNow) == complete)
    }

    @Test func aFinalLineWithoutNewlineIsCountedOnceItsNewlineArrives() async throws {
        try scratch.write("-p/a.jsonl", text: assistantLine())
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        // A complete JSON object is still an unfinished line until its newline is written.
        #expect(await scanner.scan(now: scanNow).isEmpty)

        try scratch.append("\n", to: "-p/a.jsonl")
        #expect(await scanner.scan(now: scanNow).count == 1)
    }

    @Test func truncatedFileIsRescanned() async throws {
        let url = try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(id: "msg_01TESTOLD1"), assistantLine(id: "msg_01TESTOLD2"),
                assistantLine(id: "msg_01TESTOLD3"),
            ])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).count == 3)

        // Same inode, cut down and rewritten with a different, shorter record.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((assistantLine(id: "msg_01TESTNEW1", input: 1) + "\n").utf8))
        try handle.close()

        let entries = await scanner.scan(now: scanNow)
        #expect(entries.map(\.dedupeKey) == ["msg_01TESTNEW1|req_01TESTAAAAAAAAAAAAAAAAA1"])
        #expect(entries.first?.tokens.input == 1)
    }

    @Test func replacedFileIsRescannedEvenWhenLarger() async throws {
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTOLD1")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).count == 1)

        // A new file (new inode) takes the old one's place and is larger than the recorded offset.
        let replacement = scratch.file("-p/replacement.tmp")
        try Data(
            ([
                assistantLine(id: "msg_01TESTNEW1"), assistantLine(id: "msg_01TESTNEW2"),
                assistantLine(id: "msg_01TESTNEW3"),
            ].map { $0 + "\n" }).joined().utf8
        ).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

        let keys = await scanner.scan(now: scanNow).map(\.dedupeKey)
        #expect(keys.count == 3)
        #expect(keys.allSatisfy { $0.hasPrefix("msg_01TESTNEW") })
    }

    @Test func fileWithAnOlderModificationTimeIsRescanned() async throws {
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTOLD1")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).first?.dedupeKey.hasPrefix("msg_01TESTOLD1") == true)

        // Overwrite in place with longer content, then stamp it as older than what was recorded
        // (as an archive restore or `cp -p` would). Still inside the retention window, or the file would be skipped.
        let recorded = try scratch.modificationDate(of: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(
            contentsOf: Data(
                (assistantLine(id: "msg_01TESTNEW1", padding: 400) + "\n"
                    + assistantLine(id: "msg_01TESTNEW2") + "\n").utf8))
        try handle.close()
        try scratch.setModificationDate(recorded.addingTimeInterval(-3_600), of: url)

        let keys = await scanner.scan(now: scanNow).map(\.dedupeKey)
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { $0.hasPrefix("msg_01TESTNEW") })
    }

    @Test func deletedFileIsDropped() async throws {
        try scratch.write("-p/keep.jsonl", lines: [assistantLine(id: "msg_01TESTKEEP")])
        let doomed = try scratch.write("-q/gone.jsonl", lines: [assistantLine(id: "msg_01TESTGONE")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).count == 2)

        try FileManager.default.removeItem(at: doomed)
        let remaining = await scanner.scan(now: scanNow)
        #expect(remaining.count == 1)
        #expect(remaining.first?.dedupeKey.hasPrefix("msg_01TESTKEEP") == true)

        // Removing a whole directory works the same way.
        try FileManager.default.removeItem(at: scratch.file("-p"))
        #expect(await scanner.scan(now: scanNow).isEmpty)
    }

    @Test func aFileThatReappearsIsReadFromTheStart() async throws {
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTONE")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).count == 1)

        try FileManager.default.removeItem(at: url)
        #expect(await scanner.scan(now: scanNow).isEmpty)

        try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTONE")])
        #expect(await scanner.scan(now: scanNow).count == 1)
    }

    @Test func aDeletedDuplicateKeepsTheSurvivorsEntry() async throws {
        try scratch.write("-p/a.jsonl", lines: [assistantLine(output: 10)])
        let copy = try scratch.write("-p/b.jsonl", lines: [assistantLine(output: 99)])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).first?.tokens.output == 99)

        try FileManager.default.removeItem(at: copy)
        let entries = await scanner.scan(now: scanNow)
        #expect(entries.count == 1)
        #expect(entries.first?.tokens.output == 10)
    }

    // MARK: Line size

    @Test func oversizedLineSkipped() async throws {
        // A well-formed record that is longer than the 64-byte limit is not even buffered, let alone parsed.
        let line = assistantLine()
        #expect(line.utf8.count > 64)
        try scratch.write("-p/a.jsonl", lines: [line, line])

        let scanner = TranscriptScanner(projectsDirectory: scratch.url, maxLineBytes: 64)

        #expect(await scanner.scan(now: scanNow).isEmpty)
    }

    @Test func oversizedLineDoesNotHideItsNeighbours() async throws {
        let limit = 1_000
        let atLimit = assistantLine(
            id: "msg_01TESTATLIMIT", padding: limit - assistantLine(id: "msg_01TESTATLIMIT").utf8.count)
        let overLimit = assistantLine(id: "msg_01TESTOVER", padding: 5_000)
        #expect(atLimit.utf8.count == limit)
        #expect(overLimit.utf8.count > limit)
        let justOver = assistantLine(
            id: "msg_01TESTJUSTOVER", padding: limit + 1 - assistantLine(id: "msg_01TESTJUSTOVER").utf8.count)
        #expect(justOver.utf8.count == limit + 1)
        try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(id: "msg_01TESTBEFORE"), overLimit, justOver, atLimit, "", overLimit,
                assistantLine(id: "msg_01TESTAFTER"),
            ])

        let keys = await TranscriptScanner(projectsDirectory: scratch.url, maxLineBytes: limit).scan(now: scanNow)
            .map { String($0.dedupeKey.split(separator: "|")[0]) }

        #expect(Set(keys) == ["msg_01TESTBEFORE", "msg_01TESTATLIMIT", "msg_01TESTAFTER"])
    }

    @Test func anOversizedLineStillBeingWrittenIsSkippedAcrossScans() async throws {
        let limit = 1_000
        let huge = assistantLine(id: "msg_01TESTHUGE", padding: 4_000)
        try scratch.write(
            "-p/a.jsonl", text: assistantLine(id: "msg_01TESTBEFORE") + "\n" + String(huge.prefix(1_500)))
        let scanner = TranscriptScanner(projectsDirectory: scratch.url, maxLineBytes: limit)
        #expect(await scanner.scan(now: scanNow).count == 1)

        // The line goes on with a stretch that is itself a well-formed record, then ends. That record is part of
        // the oversized line, so it must not be counted; the line after it is.
        try scratch.append(assistantLine(id: "msg_01TESTTAIL") + "\n", to: "-p/a.jsonl")
        #expect(await scanner.scan(now: scanNow).count == 1)
        try scratch.append(assistantLine(id: "msg_01TESTAFTER") + "\n", to: "-p/a.jsonl")

        let keys = await scanner.scan(now: scanNow).map { String($0.dedupeKey.split(separator: "|")[0]) }
        #expect(Set(keys) == ["msg_01TESTBEFORE", "msg_01TESTAFTER"])
    }

    @Test func chunkSizeDoesNotChangeTheResult() async throws {
        let limit = 1_000
        var lines: [String] = []
        for index in 0..<40 {
            lines.append(
                assistantLine(
                    id: "msg_01TESTBULK\(index % 25)", requestId: "req_\(index % 25)", input: index, output: index * 2,
                    timestamp: "2026-10-20T10:\(String(format: "%02d", index)):00Z"))
            if index % 7 == 0 { lines.append("garbage line \(index)") }
            if index % 9 == 0 { lines.append(assistantLine(id: "msg_01TESTHUGE\(index)", padding: 3_000)) }
            if index % 11 == 0 { lines.append("") }
        }
        try scratch.write("-p/a.jsonl", text: lines.joined(separator: "\n") + "\n" + String(lines[0].prefix(100)))
        try scratch.write("-p/s/subagents/b.jsonl", text: lines.reversed().joined(separator: "\r\n") + "\r\n")

        let reference = await TranscriptScanner(projectsDirectory: scratch.url, maxLineBytes: limit).scan(now: scanNow)
        #expect(reference.count == 25)
        for chunkSize in [1, 2, 3, 7, 64, 999, 1_000, 1_001, 4_096, 1 << 20] {
            let scanner = TranscriptScanner(
                projectsDirectory: scratch.url, maxLineBytes: limit, readChunkSize: chunkSize)
            #expect(await scanner.scan(now: scanNow) == reference, "chunk size \(chunkSize)")
        }
    }

    @Test func incrementalAppendsAgreeWithAFreshScanAtAnyChunkSize() async throws {
        let records = (0..<12).map { assistantLine(id: "msg_01TESTINC\($0)", input: $0 + 1) + "\n" }
        let everything = records.joined()
        let bytes = Array(everything.utf8)
        try scratch.write("-p/a.jsonl", text: "")
        let scanner = TranscriptScanner(projectsDirectory: scratch.url, maxLineBytes: 1_000, readChunkSize: 13)

        // Grow the file in awkward slices so that scans land in the middle of records.
        var written = 0
        for slice in stride(from: 97, through: bytes.count + 97, by: 97) {
            let end = min(slice, bytes.count)
            try scratch.append(String(decoding: bytes[written..<end], as: UTF8.self), to: "-p/a.jsonl")
            written = end
            _ = await scanner.scan(now: scanNow)
        }

        let fresh = await TranscriptScanner(projectsDirectory: scratch.url, maxLineBytes: 1_000).scan(now: scanNow)
        #expect(fresh.count == 12)
        #expect(await scanner.scan(now: scanNow) == fresh)
    }

    @Test func aFileThatComesBackWithTheSameInodeIsReadFromTheStart() async throws {
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTOLD1")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).count == 1)

        // Move the file out of the tree, change it, and move it back: same inode, larger, newer, not truncated.
        let parked = scratch.file("parked.txt")
        try FileManager.default.moveItem(at: url, to: parked)
        #expect(await scanner.scan(now: scanNow).isEmpty)
        let handle = try FileHandle(forWritingTo: parked)
        try handle.write(
            contentsOf: Data(
                (assistantLine(id: "msg_01TESTNEW1", padding: 300) + "\n" + assistantLine(id: "msg_01TESTNEW2") + "\n")
                    .utf8))
        try handle.close()
        try FileManager.default.moveItem(at: parked, to: url)

        let keys = await scanner.scan(now: scanNow).map(\.dedupeKey)
        #expect(keys.count == 2)
        #expect(keys.allSatisfy { $0.hasPrefix("msg_01TESTNEW") })
    }

    // MARK: Line assembly

    @Test func lineAssemblerSkipsAnOversizedLineWithoutBufferingIt() {
        var assembler = LineAssembler(maxLineBytes: 100, offset: 40, isSkippingLine: false)
        var lines: [String] = []
        func feed(_ text: String) {
            assembler.feed(Data(text.utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        }

        // Up to the limit the start of a line is held back, and the committed offset stays at the line start.
        feed(String(repeating: "x", count: 60))
        #expect(!assembler.isSkippingLine)
        #expect(assembler.committedOffset == 40)

        // Beyond the limit it is dropped and everything read counts as handled.
        feed(String(repeating: "x", count: 60))
        #expect(assembler.isSkippingLine)
        #expect(assembler.committedOffset == 160)
        for _ in 0..<8 { feed(String(repeating: "x", count: 60)) }
        #expect(assembler.isSkippingLine)
        #expect(assembler.committedOffset == 640)
        #expect(lines.isEmpty)

        // The end of the oversized line is discarded, the next line is delivered, and an unfinished one is held back.
        feed("xx\nok-line\npart")
        #expect(lines == ["ok-line"])
        #expect(!assembler.isSkippingLine)
        #expect(assembler.committedOffset == 651)

        feed("ial\n")
        #expect(lines == ["ok-line", "partial"])
        #expect(assembler.committedOffset == 659)
    }

    @Test func lineAssemblerResumesInsideASkippedLine() {
        var assembler = LineAssembler(maxLineBytes: 100, offset: 500, isSkippingLine: true)
        var lines: [String] = []
        assembler.feed(Data("tail of a huge line\nnext\n".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["next"])
        #expect(!assembler.isSkippingLine)
        #expect(assembler.committedOffset == 500 + 20 + 5)
    }

    @Test func lineAssemblerHandsOverEmptyLinesAndExactLimitLinesCorrectly() {
        var assembler = LineAssembler(maxLineBytes: 5, offset: 0, isSkippingLine: false)
        var lines: [String] = []
        assembler.feed(Data("\n12345\n123456\n1\n".utf8)) { lines.append(String(decoding: $0, as: UTF8.self)) }
        #expect(lines == ["12345", "1"])
        #expect(assembler.committedOffset == 1 + 6 + 7 + 2)
    }

    // MARK: File system

    @Test func onlyJsonlFilesAreRead() async throws {
        try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTYES")])
        try scratch.write("-p/a.json", lines: [assistantLine(id: "msg_01TESTNO1")])
        try scratch.write("-p/a.jsonl.bak", lines: [assistantLine(id: "msg_01TESTNO2")])
        try scratch.write("-p/notes.txt", lines: [assistantLine(id: "msg_01TESTNO3")])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(entries.count == 1)
        #expect(entries.first?.dedupeKey.hasPrefix("msg_01TESTYES") == true)
    }

    @Test func missingOrEmptyDirectoryYieldsNothing() async throws {
        #expect(await TranscriptScanner(projectsDirectory: scratch.file("nope")).scan(now: scanNow).isEmpty)
        #expect(await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow).isEmpty)
        let file = try scratch.write("plain.jsonl", lines: [assistantLine()])
        #expect(await TranscriptScanner(projectsDirectory: file).scan(now: scanNow).isEmpty)
    }

    @Test func aPipeNamedLikeATranscriptIsNeverOpened() async throws {
        try scratch.write("-p/real.jsonl", lines: [assistantLine(id: "msg_01TESTREAL001")])
        let pipe = scratch.file("-p/pipe.jsonl")
        try #require(mkfifo(pipe.path, 0o600) == 0)
        // A reader that wrongly opens the pipe would wait for a writer. Keep one open, and let it go after a moment,
        // so that such a reader fails the test instead of hanging the whole run.
        let writer = open(pipe.path, O_RDWR | O_NONBLOCK)
        try #require(writer >= 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { close(writer) }
        // A folder with a transcript's name is walked into, not read as a file.
        try FileManager.default.createDirectory(
            at: scratch.file("-p/folder.jsonl"), withIntermediateDirectories: true)

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(entries.count == 1)
        #expect(entries.first?.dedupeKey.hasPrefix("msg_01TESTREAL001") == true)
    }

    @Test func symlinksAreNeverFollowed() async throws {
        let outside = try ScratchDirectory()
        defer { outside.remove() }
        try outside.write("secret.jsonl", lines: [assistantLine(id: "msg_01TESTOUTSIDE1")])
        try outside.write("dir/deep.jsonl", lines: [assistantLine(id: "msg_01TESTOUTSIDE2")])

        try scratch.write("-p/real.jsonl", lines: [assistantLine(id: "msg_01TESTINSIDE")])
        try FileManager.default.createSymbolicLink(
            at: scratch.file("-p/linked-file.jsonl"), withDestinationURL: outside.file("secret.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: scratch.file("-p/linked-dir"), withDestinationURL: outside.file("dir"))

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(entries.count == 1)
        #expect(entries.first?.dedupeKey.hasPrefix("msg_01TESTINSIDE") == true)
    }

    @Test func aFileTurnedIntoASymlinkIsDropped() async throws {
        let outside = try ScratchDirectory()
        defer { outside.remove() }
        let target = try outside.write("elsewhere.jsonl", lines: [assistantLine(id: "msg_01TESTOUTSIDE1")])
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTINSIDE")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).count == 1)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        #expect(await scanner.scan(now: scanNow).isEmpty)
    }

    @Test func theConfiguredDirectoryItselfMayBeASymlink() async throws {
        let real = try ScratchDirectory()
        defer { real.remove() }
        try real.write("-p/a.jsonl", lines: [assistantLine()])
        let link = scratch.file("projects")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.url)

        #expect(await TranscriptScanner(projectsDirectory: link).scan(now: scanNow).count == 1)
    }

    @Test func resultsAreSortedByTimestamp() async throws {
        try scratch.write(
            "-p/z.jsonl", lines: [assistantLine(id: "msg_01TESTLATE", timestamp: "2026-10-20T12:00:00Z")])
        try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(id: "msg_01TESTMID", timestamp: "2026-10-20T11:00:00Z"),
                assistantLine(id: "msg_01TESTEARLY", timestamp: "2026-10-20T10:00:00Z"),
            ])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(
            entries.map { String($0.dedupeKey.split(separator: "|")[0]) } == [
                "msg_01TESTEARLY", "msg_01TESTMID", "msg_01TESTLATE",
            ])
    }

    @Test func repeatedScansOfAnUnchangedTreeAgree() async throws {
        try scratch.write(
            "-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTONE"), assistantLine(id: "msg_01TESTTWO")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        let first = await scanner.scan(now: scanNow)
        #expect(await scanner.scan(now: scanNow) == first)
        #expect(await scanner.scan(now: scanNow) == first)
        #expect(first.count == 2)
    }

    // MARK: Retention

    @Test func dropsEntriesOlderThanTheRetention() async throws {
        try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(id: "msg_01TESTANCIENT", timestamp: "2026-09-01T10:00:00Z"),
                assistantLine(id: "msg_01TESTEDGE", timestamp: "2026-10-13T12:00:00Z"),
                assistantLine(id: "msg_01TESTRECENT", timestamp: "2026-10-20T10:00:00Z"),
            ])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(TranscriptScanner.defaultRetention == 8 * 86_400)

        // Exactly 8 days before `scanNow` is still kept.
        let ids = await scanner.scan(now: scanNow).map { String($0.dedupeKey.split(separator: "|")[0]) }
        #expect(ids == ["msg_01TESTEDGE", "msg_01TESTRECENT"])

        // As time passes, entries age out of memory, also without any file changing.
        let dayLater = scanNow.addingTimeInterval(86_400)
        let later = await scanner.scan(now: dayLater).map { String($0.dedupeKey.split(separator: "|")[0]) }
        #expect(later == ["msg_01TESTRECENT"])

        // Forgotten entries do not come back: the lines were already read.
        #expect(await scanner.scan(now: scanNow).count == 1)
    }

    @Test func retentionIsConfigurable() async throws {
        try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(id: "msg_01TESTOLDER", timestamp: "2026-10-21T09:00:00Z"),
                assistantLine(id: "msg_01TESTNEWER", timestamp: "2026-10-21T11:30:00Z"),
            ])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url, retention: 3600)
        let entries = await scanner.scan(now: scanNow)
        #expect(entries.map { String($0.dedupeKey.split(separator: "|")[0]) } == ["msg_01TESTNEWER"])
    }

    // MARK: Files that cannot matter

    @Test func aFileLastModifiedBeforeTheRetentionWindowIsNeverOpened() async throws {
        // The old file carries a line from yesterday, which a log last written 9 days ago cannot hold. That the line is
        // not reported shows that the file was not read at all.
        let stale = try scratch.write(
            "-p/stale.jsonl", lines: [assistantLine(id: "msg_01TESTSTALE01", timestamp: "2026-10-20T10:00:00Z")])
        try scratch.setModificationDate(scanNow.addingTimeInterval(-9 * 86_400), of: stale)
        try scratch.write(
            "-p/fresh.jsonl", lines: [assistantLine(id: "msg_01TESTFRESH01", timestamp: "2026-10-20T11:00:00Z")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        let entries = await scanner.scan(now: scanNow)

        #expect(messageIDs(entries) == ["msg_01TESTFRESH01"])
        #expect(await scanner.filesOpenedByLastScan == 1)
    }

    @Test func theCutoffIsExactlyTheRetentionBeforeNow() async throws {
        let line = assistantLine(id: "msg_01TESTBORDER1", timestamp: "2026-10-13T12:00:00Z")
        let atCutoff = try scratch.write("-p/at-cutoff.jsonl", lines: [line])
        try scratch.setModificationDate(scanNow.addingTimeInterval(-TranscriptScanner.defaultRetention), of: atCutoff)
        let justBefore = try scratch.write(
            "-p/just-before.jsonl", lines: [assistantLine(id: "msg_01TESTBORDER2", timestamp: "2026-10-13T12:00:00Z")])
        try scratch.setModificationDate(
            scanNow.addingTimeInterval(-TranscriptScanner.defaultRetention - 1), of: justBefore)
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        // A file touched at the cutoff may still hold a line from that very moment; one second earlier cannot.
        #expect(messageIDs(await scanner.scan(now: scanNow)) == ["msg_01TESTBORDER1"])
        #expect(await scanner.filesOpenedByLastScan == 1)
    }

    @Test func aFileThatAgesOutIsForgottenAndReadFromTheStartIfItIsTouchedAgain() async throws {
        let url = try scratch.write(
            "-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTAGING01", timestamp: "2026-10-20T10:00:00Z")])
        try scratch.setModificationDate(scanNow.addingTimeInterval(-3_600), of: url)
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(messageIDs(await scanner.scan(now: scanNow)) == ["msg_01TESTAGING01"])

        // 9 days later nothing has touched it: it is neither opened nor remembered.
        let later = scanNow.addingTimeInterval(9 * 86_400)
        #expect(await scanner.scan(now: later).isEmpty)
        #expect(await scanner.filesOpenedByLastScan == 0)

        // Claude Code resumes the session. The file is read from its first byte, and the old line stays out.
        try scratch.append(
            assistantLine(id: "msg_01TESTAGING02", timestamp: "2026-10-29T10:00:00Z") + "\n", to: "-p/a.jsonl")
        try scratch.setModificationDate(later.addingTimeInterval(-3_600), of: url)
        #expect(messageIDs(await scanner.scan(now: later)) == ["msg_01TESTAGING02"])
        #expect(await scanner.filesOpenedByLastScan == 1)
    }

    @Test func aRecentFileDoesNotKeepItsOldLines() async throws {
        try scratch.write(
            "-p/a.jsonl",
            lines: [
                assistantLine(id: "msg_01TESTNINEDAY1", timestamp: "2026-10-12T12:00:00Z"),
                assistantLine(id: "msg_01TESTYESTERDA", timestamp: "2026-10-20T12:00:00Z"),
            ])
        // The same old response again in a second recent file (a resumed session) does not bring it back either.
        try scratch.write(
            "-p/b.jsonl", lines: [assistantLine(id: "msg_01TESTNINEDAY1", timestamp: "2026-10-12T12:00:00Z")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        #expect(messageIDs(await scanner.scan(now: scanNow)) == ["msg_01TESTYESTERDA"])
        #expect(messageIDs(await scanner.scan(now: scanNow)) == ["msg_01TESTYESTERDA"])
    }

    // MARK: Files that did not change

    @Test func anUnchangedFileIsNotOpenedAgain() async throws {
        try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTSTILL01")])
        try scratch.write("-q/b.jsonl", lines: [assistantLine(id: "msg_01TESTSTILL02")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        let first = await scanner.scan(now: scanNow)
        #expect(first.count == 2)
        #expect(await scanner.filesOpenedByLastScan == 2)

        #expect(await scanner.scan(now: scanNow) == first)
        #expect(await scanner.filesOpenedByLastScan == 0)

        // Only the file that grew is opened, and only its new bytes are parsed.
        try scratch.append(assistantLine(id: "msg_01TESTSTILL03") + "\n", to: "-p/a.jsonl")
        #expect(await scanner.scan(now: scanNow).count == 3)
        #expect(await scanner.filesOpenedByLastScan == 1)

        #expect(await scanner.scan(now: scanNow).count == 3)
        #expect(await scanner.filesOpenedByLastScan == 0)
    }

    @Test func aFileEndingInAPartialLineIsOpenedAgainOnlyWhenItChanges() async throws {
        let second = assistantLine(id: "msg_01TESTPARTIAL2")
        let splitAt = second.index(second.startIndex, offsetBy: second.count / 2)
        try scratch.write(
            "-p/a.jsonl", text: assistantLine(id: "msg_01TESTPARTIAL1") + "\n" + String(second[..<splitAt]))
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        #expect(await scanner.scan(now: scanNow).count == 1)
        #expect(await scanner.scan(now: scanNow).count == 1)
        #expect(await scanner.filesOpenedByLastScan == 0)

        try scratch.append(String(second[splitAt...]) + "\n", to: "-p/a.jsonl")
        #expect(await scanner.scan(now: scanNow).count == 2)
        #expect(await scanner.filesOpenedByLastScan == 1)
    }

    @Test func aFileTouchedWithoutGrowingIsOpenedOnceAndReadNoFurther() async throws {
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTTOUCH01")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        let first = await scanner.scan(now: scanNow)

        try scratch.setModificationDate(try scratch.modificationDate(of: url).addingTimeInterval(60), of: url)

        #expect(await scanner.scan(now: scanNow) == first)
        #expect(await scanner.filesOpenedByLastScan == 1)
        #expect(await scanner.scan(now: scanNow) == first)
        #expect(await scanner.filesOpenedByLastScan == 0)
    }

    @Test func aReplacedFileIsOpenedEvenWhenItLooksTheSame() async throws {
        let url = try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTSAMEAS01", input: 111)])
        let stamp = try scratch.modificationDate(of: url)
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)
        #expect(await scanner.scan(now: scanNow).first?.tokens.input == 111)

        // Same size, same modification time, but another file (another inode) with other numbers.
        let replacement = scratch.file("-p/replacement.tmp")
        try Data((assistantLine(id: "msg_01TESTSAMEAS01", input: 222) + "\n").utf8).write(to: replacement)
        try scratch.setModificationDate(stamp, of: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)
        try scratch.setModificationDate(stamp, of: url)

        #expect(await scanner.scan(now: scanNow).first?.tokens.input == 222)
        #expect(await scanner.filesOpenedByLastScan == 1)
    }

    // MARK: Listing

    @Test func listsSubdirectoriesAtAnyUsualDepth() async throws {
        try scratch.write("a.jsonl", lines: [assistantLine(id: "msg_01TESTDEPTH000")])
        try scratch.write("-p/s/subagents/deeper/b.jsonl", lines: [assistantLine(id: "msg_01TESTDEPTH004")])
        try scratch.write("-p/.hidden/c.jsonl", lines: [assistantLine(id: "msg_01TESTDEPTH003")])
        try scratch.write("-p/.d.jsonl", lines: [assistantLine(id: "msg_01TESTDEPTH002")])
        try scratch.write("-p/.jsonl", lines: [assistantLine(id: "msg_01TESTDEPTH001")])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        // Hidden folders and files are read; a file that is nothing but the extension is not a transcript.
        #expect(
            messageIDs(entries).sorted() == [
                "msg_01TESTDEPTH000", "msg_01TESTDEPTH002", "msg_01TESTDEPTH003", "msg_01TESTDEPTH004",
            ])
    }

    @Test func foldersNestedBeyondTheDepthLimitAreNotListed() async throws {
        let levels = Array(repeating: "d", count: 33)
        // 32 folders below the projects directory are listed, a 33rd is not.
        try scratch.write(
            levels.prefix(32).joined(separator: "/") + "/in.jsonl", lines: [assistantLine(id: "msg_01TESTLISTED01")])
        try scratch.write(
            levels.joined(separator: "/") + "/out.jsonl", lines: [assistantLine(id: "msg_01TESTSKIPPED1")])

        let entries = await TranscriptScanner(projectsDirectory: scratch.url).scan(now: scanNow)

        #expect(messageIDs(entries) == ["msg_01TESTLISTED01"])
    }

    // MARK: Cancellation

    @Test func aCancelledTaskReadsNothingAndLosesNothing() async throws {
        try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTCANCEL01")])
        try scratch.write("-p/b.jsonl", lines: [assistantLine(id: "msg_01TESTCANCEL02")])
        let scanner = TranscriptScanner(projectsDirectory: scratch.url)

        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await scanner.scan(now: scanNow)
        }
        task.cancel()

        #expect(await task.value.isEmpty)
        #expect(await scanner.filesOpenedByLastScan == 0)
        // The next scan is not held back by it.
        #expect(await scanner.scan(now: scanNow).count == 2)
        #expect(await scanner.filesOpenedByLastScan == 2)
    }

    @Test func cancellingBetweenFilesKeepsTheFilesAlreadyRead() async throws {
        for name in ["a", "b", "c"] {
            try scratch.write("-p/\(name).jsonl", lines: [assistantLine(id: "msg_01TESTBETWEEN\(name)")])
        }
        // The checks: two directories; then for the first file one before it, one before its chunk and one before
        // looking for more. The next one, before "b", is the first to say stop.
        let cancel = CancelAfter(allowedChecks: 5)
        let scanner = TranscriptScanner(
            projectsDirectory: scratch.url, maxLineBytes: 10_485_760, readChunkSize: 1 << 20,
            isCancelled: { cancel.check() })

        let partial = await scanner.scan(now: scanNow)
        #expect(messageIDs(partial) == ["msg_01TESTBETWEENa"])
        #expect(await scanner.filesOpenedByLastScan == 1)

        // The next scan goes on with the files not yet read, and does not open the first one again.
        cancel.allow(.max)
        #expect(
            messageIDs(await scanner.scan(now: scanNow)) == [
                "msg_01TESTBETWEENa", "msg_01TESTBETWEENb", "msg_01TESTBETWEENc",
            ])
        #expect(await scanner.filesOpenedByLastScan == 2)
    }

    @Test func cancellingBetweenChunksStopsInsideTheFileAndTheNextScanFinishesIt() async throws {
        let lines = (1...3).map { assistantLine(id: "msg_01TESTCHUNKED0\($0)") }
        try scratch.write("-p/a.jsonl", lines: lines)
        let oneLine = lines[0].utf8.count + 1
        // Two directories, the file, and the chunk with the first line: the check before the second chunk says stop.
        let cancel = CancelAfter(allowedChecks: 4)
        let scanner = TranscriptScanner(
            projectsDirectory: scratch.url, maxLineBytes: 10_485_760, readChunkSize: oneLine,
            isCancelled: { cancel.check() })

        #expect(messageIDs(await scanner.scan(now: scanNow)) == ["msg_01TESTCHUNKED01"])
        #expect(await scanner.filesOpenedByLastScan == 1)

        // The file is unchanged, but it was not read to its end, so it is opened again, from where it stopped.
        cancel.allow(.max)
        #expect(
            messageIDs(await scanner.scan(now: scanNow)) == [
                "msg_01TESTCHUNKED01", "msg_01TESTCHUNKED02", "msg_01TESTCHUNKED03",
            ])
        #expect(await scanner.filesOpenedByLastScan == 1)

        #expect(await scanner.scan(now: scanNow).count == 3)
        #expect(await scanner.filesOpenedByLastScan == 0)
    }

    @Test func aScanCancelledWhileListingForgetsNothing() async throws {
        try scratch.write("-p/a.jsonl", lines: [assistantLine(id: "msg_01TESTLISTING1")])
        try scratch.write("-q/b.jsonl", lines: [assistantLine(id: "msg_01TESTLISTING2")])
        let cancel = CancelAfter(allowedChecks: .max)
        let scanner = TranscriptScanner(
            projectsDirectory: scratch.url, maxLineBytes: 10_485_760, readChunkSize: 1 << 20,
            isCancelled: { cancel.check() })
        #expect(await scanner.scan(now: scanNow).count == 2)

        // Stopped before the first directory was read: the listing is empty, which does not mean the files are gone.
        cancel.allow(0)
        _ = await scanner.scan(now: scanNow)
        cancel.allow(.max)

        #expect(await scanner.scan(now: scanNow).count == 2)
        #expect(await scanner.filesOpenedByLastScan == 0)
    }
}

private func messageIDs(_ entries: [TranscriptEntry]) -> [String] {
    entries.map { String($0.dedupeKey.split(separator: "|")[0]) }
}
