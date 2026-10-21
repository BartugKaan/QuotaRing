import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct TranscriptEntryTests {
    @Test func totalAddsEveryField() {
        #expect(TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4).total == 10)
        #expect(TokenCounts.zero.total == 0)
        #expect(TokenCounts.zero == TokenCounts())
    }

    @Test func plusAddsFieldwise() {
        let a = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
        let b = TokenCounts(input: 10, output: 20, cacheWrite: 30, cacheRead: 40)
        #expect(a + b == TokenCounts(input: 11, output: 22, cacheWrite: 33, cacheRead: 44))
        var sum = TokenCounts.zero
        sum += a
        sum += b
        #expect(sum == a + b)
    }

    @Test func fieldwiseMaxTakesTheLargerOfEachField() {
        let a = TokenCounts(input: 5, output: 1, cacheWrite: 0, cacheRead: 100)
        let b = TokenCounts(input: 3, output: 9, cacheWrite: 7, cacheRead: 100)
        let expected = TokenCounts(input: 5, output: 9, cacheWrite: 7, cacheRead: 100)
        #expect(a.fieldwiseMax(b) == expected)
        #expect(b.fieldwiseMax(a) == expected)
        #expect(a.fieldwiseMax(a) == a)
    }

    @Test func arithmeticSaturatesInsteadOfTrapping() {
        let huge = TokenCounts(input: Int.max, output: Int.max, cacheWrite: 1, cacheRead: 1)
        #expect(huge.total == Int.max)
        #expect((huge + huge).input == Int.max)
        #expect((huge + huge).cacheRead == 2)
    }

    @Test func codableRoundTripsTheFourCounters() throws {
        let counts = TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)
        let data = try JSONEncoder().encode(counts)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(Set(object.keys) == ["input", "output", "cacheWrite", "cacheRead"])
        #expect(try JSONDecoder().decode(TokenCounts.self, from: data) == counts)
    }

    @Test func mergingKeepsMaxTokensEarliestTimestampAndFirstKnownLabels() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let first = TranscriptEntry(
            dedupeKey: "k", timestamp: late, model: "Unknown", project: "Unknown",
            tokens: TokenCounts(input: 1, output: 10))
        let second = TranscriptEntry(
            dedupeKey: "k", timestamp: early, model: "claude-opus-4-8", project: "alpha",
            tokens: TokenCounts(input: 4, output: 2))
        let third = TranscriptEntry(
            dedupeKey: "k", timestamp: late, model: "claude-haiku-4-5", project: "beta",
            tokens: .zero)

        let merged = first.merged(with: second).merged(with: third)
        #expect(merged.dedupeKey == "k")
        #expect(merged.timestamp == early)
        #expect(merged.model == "claude-opus-4-8")
        #expect(merged.project == "alpha")
        #expect(merged.tokens == TokenCounts(input: 4, output: 10))
    }
}
