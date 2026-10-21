import Foundation
import Testing

@testable import QuotaRingCore

/// Builds one transcript line shaped like a real Claude Code assistant record (fake ids and paths).
///
/// Shared by the scanner tests. `padding` appends a filler field so a line can be made an exact length.
func assistantLine(
    id: String = "msg_01TESTAAAAAAAAAAAAAAAAA1",
    requestId: String? = "req_01TESTAAAAAAAAAAAAAAAAA1",
    model: String? = "claude-opus-4-8",
    input: Int = 7021,
    output: Int = 302,
    cacheWrite: Int = 17371,
    cacheRead: Int = 0,
    timestamp: String = "2026-10-20T20:35:00.527Z",
    cwd: String? = "/Users/test/dev/alpha",
    padding: Int = 0
) -> String {
    var message =
        "\"id\":\"\(id)\",\"type\":\"message\",\"role\":\"assistant\""
        + (model.map { ",\"model\":\"\($0)\"" } ?? "")
        + ",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"stop_reason\":null"
        + ",\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(cacheWrite)"
        + ",\"cache_read_input_tokens\":\(cacheRead),\"output_tokens\":\(output)"
        + ",\"service_tier\":\"standard\"}"
    message = "{" + message + "}"
    var line =
        "{\"parentUuid\":null,\"isSidechain\":false,\"userType\":\"external\""
        + (cwd.map { ",\"cwd\":\"\($0)\"" } ?? "")
        + ",\"sessionId\":\"5e55a1a1-0000-4000-8000-000000000001\",\"version\":\"2.1.0\",\"gitBranch\":\"main\""
        + ",\"message\":\(message)"
        + (requestId.map { ",\"requestId\":\"\($0)\"" } ?? "")
        + ",\"type\":\"assistant\",\"uuid\":\"00000000-0000-4000-8000-000000000009\""
        + ",\"timestamp\":\"\(timestamp)\"}"
    if padding > 0 {
        line.removeLast()
        line += ",\"pad\":\"" + String(repeating: "x", count: max(0, padding - 9)) + "\"}"
    }
    return line
}

@Suite struct TranscriptLineParserTests {
    private func parse(_ line: String) -> TranscriptEntry? {
        TranscriptLineParser.parse(Data(line.utf8))
    }

    @Test func parsesRealShapedLine() throws {
        let entry = try #require(parse(assistantLine()))

        #expect(entry.dedupeKey == "msg_01TESTAAAAAAAAAAAAAAAAA1|req_01TESTAAAAAAAAAAAAAAAAA1")
        #expect(entry.model == "claude-opus-4-8")
        #expect(entry.project == "alpha")
        #expect(entry.tokens == TokenCounts(input: 7021, output: 302, cacheWrite: 17371, cacheRead: 0))
        #expect(entry.tokens.total == 24_694)
        let expected = try #require(FlexibleDate.parse("2026-10-20T20:35:00.527Z"))
        #expect(entry.timestamp == expected)
        #expect(abs(entry.timestamp.timeIntervalSince1970 - 1_792_528_500.527) < 0.001)
    }

    @Test func parsesTheFixtureAssistantLine() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "session-a1", withExtension: "jsonl",
                subdirectory: "Fixtures/transcripts/-Users-test-dev-alpha"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        let entries = lines.compactMap { parse($0) }
        // 3 content-block lines for one message plus the haiku message; user, synthetic and truncated lines drop out.
        #expect(entries.count == 4)
        #expect(Set(entries.map(\.dedupeKey)).count == 2)
    }

    @Test func missingRequestIdLeavesAnEmptySuffix() throws {
        let entry = try #require(parse(assistantLine(id: "msg_01TESTNOREQ", requestId: nil)))
        #expect(entry.dedupeKey == "msg_01TESTNOREQ|")
    }

    @Test func nonAssistantLinesAreIgnored() {
        let user = """
            {"type":"user","message":{"role":"user","content":"hi","id":"msg_01TESTUSER","usage":{"input_tokens":1}},\
            "timestamp":"2026-10-20T20:35:00.527Z","cwd":"/Users/test/dev/alpha"}
            """
        #expect(parse(user) == nil)
        let summary = #"{"type":"summary","summary":"x","leafUuid":"00000000-0000-4000-8000-000000000001"}"#
        #expect(parse(summary) == nil)
        let system = assistantLine().replacingOccurrences(of: "\"type\":\"assistant\"", with: "\"type\":\"system\"")
        #expect(parse(system) == nil)
    }

    @Test func syntheticModelIsIgnored() {
        #expect(parse(assistantLine(model: "<synthetic>", input: 0, output: 0, cacheWrite: 0)) == nil)
    }

    @Test func missingIdentityOrUsageIsIgnored() {
        let noId = assistantLine().replacingOccurrences(of: "\"id\":\"msg_01TESTAAAAAAAAAAAAAAAAA1\",", with: "")
        #expect(parse(noId) == nil)
        let emptyId = assistantLine(id: "")
        #expect(parse(emptyId) == nil)
        let noUsage = assistantLine().replacingOccurrences(of: "\"usage\"", with: "\"usages\"")
        #expect(parse(noUsage) == nil)
        let usageNotAnObject = assistantLine().replacingOccurrences(
            of: "\"usage\":{", with: "\"usage\":[{"
        ).replacingOccurrences(of: "\"standard\"}", with: "\"standard\"}]")
        #expect(parse(usageNotAnObject) == nil)
        let noTimestamp = assistantLine().replacingOccurrences(
            of: ",\"timestamp\":\"2026-10-20T20:35:00.527Z\"", with: "")
        #expect(parse(noTimestamp) == nil)
        #expect(parse(assistantLine(timestamp: "yesterday")) == nil)
    }

    @Test func garbageIsIgnored() {
        #expect(parse("") == nil)
        #expect(parse("   ") == nil)
        #expect(parse("not json at all") == nil)
        #expect(parse("[1,2,3]") == nil)
        #expect(parse("null") == nil)
        #expect(parse("42") == nil)
        #expect(parse(#"{"type":"assistant","message":{"id":"msg_01TESTTRUNCATED"#) == nil)
        #expect(TranscriptLineParser.parse(Data([0xFF, 0xFE, 0x00, 0x7B])) == nil)
        #expect(TranscriptLineParser.parse(Data()) == nil)
    }

    @Test func projectComesFromTheLastPathComponentOfCwd() throws {
        #expect(try #require(parse(assistantLine(cwd: "/Users/test/dev/alpha/"))).project == "alpha")
        #expect(try #require(parse(assistantLine(cwd: "/Users/test/dev/my app"))).project == "my app")
        #expect(try #require(parse(assistantLine(cwd: "beta"))).project == "beta")
        #expect(try #require(parse(assistantLine(cwd: nil))).project == "Unknown")
        #expect(try #require(parse(assistantLine(cwd: ""))).project == "Unknown")
        #expect(try #require(parse(assistantLine(cwd: "/"))).project == "Unknown")
    }

    @Test func missingModelIsCountedAsUnknown() throws {
        let entry = try #require(parse(assistantLine(model: nil)))
        #expect(entry.model == "Unknown")
        #expect(entry.tokens.input == 7021)
    }

    @Test func missingOrOddTokenFieldsCountAsZero() throws {
        let bare = """
            {"type":"assistant","timestamp":"2026-10-20T20:35:00Z","message":{"id":"m","model":"claude-opus-4-8",\
            "usage":{"input_tokens":5,"output_tokens":"many","cache_read_input_tokens":-9,\
            "cache_creation_input_tokens":2.0}}}
            """
        let entry = try #require(parse(bare))
        #expect(entry.tokens == TokenCounts(input: 5, output: 0, cacheWrite: 2, cacheRead: 0))

        let empty = #"{"type":"assistant","timestamp":1792528500,"message":{"id":"m","usage":{}}}"#
        let emptyEntry = try #require(parse(empty))
        #expect(emptyEntry.tokens == .zero)
        #expect(emptyEntry.timestamp == Date(timeIntervalSince1970: 1_792_528_500))
    }

    @Test func tokenValuesLargerThanAnyRealCountAreNotTrusted() throws {
        let entry = try #require(parse(assistantLine(input: 9_000_000_000_000_000_000)))
        #expect(entry.tokens.input == 0)
    }
}
