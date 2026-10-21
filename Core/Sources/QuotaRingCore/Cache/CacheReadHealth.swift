import Foundation

/// Decides when a failure to read Claude Code's cache is worth telling the user about.
///
/// Claude Code rewrites `~/.claude.json` often, and a read that overlaps a write sees a half-written file, so one
/// ``CacheReadError/malformed`` result is normal and is followed by a good read once the write is done. A file that is
/// too large or cannot be opened, or one that stays malformed for ``malformedGracePeriod``, is a real problem: the
/// numbers on screen stop updating, and the user should know why.
///
/// ``CacheReadError/accountMismatch`` is not a read problem (the file was read fine) and is never reported here.
public struct CacheReadHealth: Equatable, Sendable {
    /// How long the file may stay malformed before it is reported.
    public static let malformedGracePeriod: TimeInterval = 90

    /// The last read's error, `nil` after a good read.
    public private(set) var lastError: CacheReadError?
    /// When the current run of failed reads began.
    public private(set) var failingSince: Date?

    public init() {}

    /// Records a read that worked (with or without a usage entry, or a file that does not exist).
    public mutating func recordSuccess() {
        lastError = nil
        failingSince = nil
    }

    /// Records a failed read at `now`.
    public mutating func recordFailure(_ error: CacheReadError, at now: Date) {
        guard error != .accountMismatch else {
            recordSuccess()
            return
        }
        if lastError == nil {
            failingSince = now
        }
        lastError = error
    }

    /// The problem to show at `now`, or `nil` when there is none (yet).
    public func problem(at now: Date) -> CacheReadError? {
        guard let lastError, let failingSince else { return nil }
        switch lastError {
        case .fileTooLarge, .unreadable:
            return lastError
        case .malformed:
            return now.timeIntervalSince(failingSince) >= Self.malformedGracePeriod ? lastError : nil
        case .accountMismatch:
            return nil
        }
    }
}
