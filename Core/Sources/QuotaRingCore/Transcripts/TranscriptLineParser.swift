import Foundation

/// Reads one line of a Claude Code JSONL transcript.
public enum TranscriptLineParser {
    /// Every line that carries usage spells the key out as `"usage"`; the many other lines (user turns, tool
    /// results, summaries) can be rejected on this byte pattern before paying for a JSON parse.
    private static let usageMarker = Data("\"usage\"".utf8)

    /// The upper bound for a believable token counter. Larger numbers are corrupt, not data.
    private static let maximumTokenCount = 1_000_000_000_000

    /// Returns the response described by `line`, or `nil` when the line is not a usable assistant record.
    ///
    /// Only `type == "assistant"` lines with a `message.id`, a `message.usage` object and a parseable `timestamp`
    /// qualify. Responses from the `<synthetic>` model, which Claude Code writes for local notices, are skipped.
    /// A missing model is recorded as `"Unknown"` so that its tokens are still counted.
    public static func parse(_ line: Data) -> TranscriptEntry? {
        guard line.range(of: usageMarker) != nil else { return nil }
        guard
            let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            root["type"] as? String == "assistant",
            let message = JSONValue.object(root["message"]),
            let messageID = JSONValue.nonEmptyString(message["id"]),
            let usage = JSONValue.object(message["usage"]),
            let timestamp = FlexibleDate.parse(root["timestamp"])
        else { return nil }

        let model = JSONValue.nonEmptyString(message["model"]) ?? TranscriptEntry.unknownLabel
        guard model != "<synthetic>" else { return nil }

        let requestID = JSONValue.nonEmptyString(root["requestId"]) ?? ""
        return TranscriptEntry(
            dedupeKey: messageID + "|" + requestID,
            timestamp: timestamp,
            model: model,
            project: project(fromWorkingDirectory: JSONValue.nonEmptyString(root["cwd"])),
            tokens: TokenCounts(
                input: count(usage["input_tokens"]),
                output: count(usage["output_tokens"]),
                cacheWrite: count(usage["cache_creation_input_tokens"]),
                cacheRead: count(usage["cache_read_input_tokens"])))
    }

    private static func count(_ value: Any?) -> Int {
        guard let number = JSONValue.int(value), (0...maximumTokenCount).contains(number) else { return 0 }
        return number
    }

    private static func project(fromWorkingDirectory cwd: String?) -> String {
        guard let name = cwd?.split(separator: "/", omittingEmptySubsequences: true).last else {
            return TranscriptEntry.unknownLabel
        }
        return String(name)
    }
}
