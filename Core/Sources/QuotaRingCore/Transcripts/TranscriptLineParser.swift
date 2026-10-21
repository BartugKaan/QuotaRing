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
            project: projectName(fromCWD: JSONValue.nonEmptyString(root["cwd"]) ?? ""),
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

    /// Names the project a working directory belongs to.
    ///
    /// The rule is purely lexical (no file system access). Empty path components, as left by a leading or trailing
    /// `/`, are ignored. Scanning from the outermost folder inward, the first of these markers decides:
    ///
    /// - `<repo>/.claude/worktrees/<name>[/...]`: Claude Code's subagent and worktree folders; the project is `<repo>`,
    ///   the folder that contains `.claude`.
    /// - `<repo>/.worktrees/<name>[/...]` and `<repo>/worktrees/<name>[/...]`: the common git worktree layouts; the
    ///   project is `<repo>`, the folder directly above the marker.
    ///
    /// A marker only counts when a `<name>` folder follows it and a `<repo>` folder precedes it, so a working directory
    /// that is itself `worktrees` (or `.claude/worktrees`) is not rewritten. Without a marker the project is the last
    /// path component, and `"Unknown"` when there is none (empty string or `/`).
    static func projectName(fromCWD cwd: String) -> String {
        let components = cwd.split(separator: "/", omittingEmptySubsequences: true)
        for index in components.indices.dropFirst() {
            let name = components[index]
            let isClaudeWorktrees =
                name == ".claude" && index + 2 < components.endIndex && components[index + 1] == "worktrees"
            let isPlainWorktrees =
                (name == ".worktrees" || name == "worktrees") && index + 1 < components.endIndex
                && components[index - 1] != ".claude"
            if isClaudeWorktrees || isPlainWorktrees {
                return String(components[index - 1])
            }
        }
        return components.last.map(String.init) ?? TranscriptEntry.unknownLabel
    }
}
