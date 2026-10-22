import Foundation

/// Token counts for one assistant response, split the way the usage block of a transcript line reports them.
public struct TokenCounts: Hashable, Sendable, Codable {
    public var input: Int
    public var output: Int
    /// `cache_creation_input_tokens`.
    public var cacheWrite: Int
    /// `cache_read_input_tokens`.
    public var cacheRead: Int

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    /// Input, output and both cache counters together. Saturates at `Int.max` instead of trapping.
    public var total: Int {
        Self.saturatingAdd(Self.saturatingAdd(input, output), Self.saturatingAdd(cacheWrite, cacheRead))
    }

    public static let zero = TokenCounts()

    public static func + (lhs: TokenCounts, rhs: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: saturatingAdd(lhs.input, rhs.input),
            output: saturatingAdd(lhs.output, rhs.output),
            cacheWrite: saturatingAdd(lhs.cacheWrite, rhs.cacheWrite),
            cacheRead: saturatingAdd(lhs.cacheRead, rhs.cacheRead))
    }

    public static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs = lhs + rhs
    }

    /// The larger value of each counter.
    ///
    /// A message that is streamed is written once per content block, and the counters on those lines grow as the
    /// stream goes on, so the line with the largest counters holds the final numbers.
    public func fieldwiseMax(_ other: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: max(input, other.input),
            output: max(output, other.output),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            cacheRead: max(cacheRead, other.cacheRead))
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard overflowed else { return sum }
        return rhs < 0 ? Int.min : Int.max
    }
}

/// One assistant response found in a local Claude Code transcript.
public struct TranscriptEntry: Hashable, Sendable {
    /// `message.id + "|" + (requestId ?? "")`. Lines that share a key describe the same response.
    public var dedupeKey: String
    public var timestamp: Date
    /// The model id exactly as written in the transcript, e.g. `claude-opus-4-8`.
    public var model: String
    /// The repository folder of the working directory (worktree folders map to their repository), or `"Unknown"`.
    public var project: String
    public var tokens: TokenCounts

    public init(dedupeKey: String, timestamp: Date, model: String, project: String, tokens: TokenCounts) {
        self.dedupeKey = dedupeKey
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.tokens = tokens
    }

    /// Placeholder for a project or model that a line did not name.
    static let unknownLabel = "Unknown"

    /// Combines two sightings of the same response: the larger counters, the earliest timestamp, and the first
    /// model and project that are not `"Unknown"` (the receiver's win when both are known).
    func merged(with other: TranscriptEntry) -> TranscriptEntry {
        TranscriptEntry(
            dedupeKey: dedupeKey,
            timestamp: min(timestamp, other.timestamp),
            model: model == Self.unknownLabel ? other.model : model,
            project: project == Self.unknownLabel ? other.project : project,
            tokens: tokens.fieldwiseMax(other.tokens))
    }
}
