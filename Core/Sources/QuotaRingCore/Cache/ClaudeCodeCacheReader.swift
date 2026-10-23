import Foundation

/// Why Claude Code's cached usage snapshot could not be read.
///
/// The cases deliberately carry no payload: the file they come from also holds unrelated, sensitive configuration
/// (MCP server environments, account details) that must never end up in an error message or a log.
public enum CacheReadError: Error, Equatable {
    /// The file is larger than the reader's `maxFileSize`.
    case fileTooLarge
    /// The file exists but could not be inspected or read (permissions, I/O error, not a regular file).
    case unreadable
    /// The file is not valid JSON, or the `cachedUsageUtilization` entry does not have the expected shape.
    case malformed
    /// The cached entry and `oauthAccount` name different accounts: the cache belongs to an account that is no longer
    /// signed in, so nothing read from it (or saved from it earlier) should be shown.
    case accountMismatch
}

/// Cheap change detector for a file: two equal fingerprints mean the file very probably did not change.
public struct FileFingerprint: Equatable, Sendable {
    public var size: Int64
    public var modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }
}

/// Reads the usage snapshot Claude Code itself caches in its global config file (`~/.claude.json`).
///
/// This is QuotaRing's default, token-free data source. The file is mostly unrelated configuration, some of it
/// sensitive, so exactly one key is ever extracted: `cachedUsageUtilization`, plus `oauthAccount.accountUuid` for
/// the account check. Everything else is dropped as soon as the document is parsed and is never stored, returned or
/// attached to an error. The file is only ever read, never written.
public struct ClaudeCodeCacheReader: Sendable {
    /// The config file to read, normally ``ClaudePaths/globalConfigFile``.
    public let fileURL: URL
    /// Files larger than this many bytes are rejected without being read. Defaults to 50 MB.
    public let maxFileSize: Int64

    public init(fileURL: URL, maxFileSize: Int64 = 52_428_800) {
        self.fileURL = fileURL
        self.maxFileSize = maxFileSize
    }

    /// The file's current size and modification date, or `nil` when it cannot be inspected (for example when it does
    /// not exist). Does not read the file's contents.
    public func fingerprint() -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath) else { return nil }
        return Self.fingerprint(from: attributes)
    }

    /// Extracts the cached usage snapshot.
    ///
    /// - Returns: A snapshot with source ``SnapshotSource/claudeCodeCache``, or `nil` when there is nothing usable
    ///   to show: the file does not exist, or it has no `cachedUsageUtilization` entry (absent or `null`).
    /// - Throws: ``CacheReadError/fileTooLarge`` for an oversized file (checked before any bytes are read),
    ///   ``CacheReadError/unreadable`` for any other I/O or permission failure, ``CacheReadError/malformed``
    ///   when the JSON cannot be parsed or `cachedUsageUtilization` has the wrong shape (missing or invalid
    ///   `fetchedAtMs`, a `fetchedAtMs` more than ``UsageSnapshot/maxFutureSkew`` after `now`, or a `utilization` the
    ///   usage decoder cannot use), and ``CacheReadError/accountMismatch`` when the entry and `oauthAccount` both name
    ///   an account and the two differ (the cache belongs to someone else).
    public func read(now: Date = Date()) throws -> UsageSnapshot? {
        guard let data = try readContents() else { return nil }
        return try Self.extractSnapshot(from: data, now: now)
    }

    /// Reads the file through one descriptor: it is opened once, checked with `fstat` on that descriptor and read from
    /// it, so it cannot be swapped between the check and the read (the same pattern as ``FileCredentialSource``).
    ///
    /// Symbolic links are followed, because a symlinked `~/.claude.json` is a common dotfile-manager setup; the checks
    /// apply to the file the link points to. `O_NONBLOCK` keeps a FIFO from making `open(2)` wait for a writer (it has
    /// no effect on a regular file), and the `fstat` check then refuses it. Anything but a regular file (a directory,
    /// FIFO, socket or device) is refused, because it can block a read or report a size of 0 and so slip past the cap.
    ///
    /// - Returns: The contents, or `nil` when nothing exists at the path.
    private func readContents() throws(CacheReadError) -> Data? {
        let path = fileURL.path
        var descriptor: Int32 = -1
        var openError: Int32 = 0
        for _ in 0..<3 {
            descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            openError = descriptor < 0 ? errno : 0
            if openError != EINTR { break }
        }
        guard descriptor >= 0 else {
            // A symlink whose target is gone also fails with ENOENT. The path itself exists then, so it is reported as
            // unreadable rather than as "no cache", as it was when the file was inspected by path.
            var linkInfo = stat()
            if openError == ENOENT, lstat(path, &linkInfo) != 0 { return nil }
            throw .unreadable
        }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw .unreadable
        }
        guard Int64(info.st_size) <= maxFileSize else {
            throw .fileTooLarge
        }
        return try Self.readAll(descriptor, capacity: Int(info.st_size), limit: maxFileSize)
    }

    /// Reads to end of file, refusing to go past `limit` bytes if the file grew after `fstat`. (Not private so that
    /// tests can feed it a descriptor that yields more than `fstat` promised, or one that fails.)
    static func readAll(_ descriptor: Int32, capacity: Int, limit: Int64) throws(CacheReadError) -> Data {
        var data = Data(capacity: max(0, capacity))
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable
            }
            data.append(contentsOf: chunk[0..<count])
            guard Int64(data.count) <= limit else { throw .fileTooLarge }
        }
    }

    // MARK: - Private

    /// `attributesOfItem` describes a symbolic link itself rather than its target, which would make the fingerprint
    /// meaningless for a symlinked `~/.claude.json` (a common dotfile-manager setup).
    private var resolvedPath: String {
        fileURL.resolvingSymlinksInPath().path
    }

    private static func fingerprint(from attributes: [FileAttributeKey: Any]) -> FileFingerprint? {
        guard
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return FileFingerprint(size: size, modified: modified)
    }

    /// Parses the document, keeps only the cache entry (and the account UUIDs needed to vet it) and lets the rest of
    /// the tree go out of scope. Parser errors are discarded because their descriptions can quote file contents.
    private static func extractSnapshot(from data: Data, now: Date) throws -> UsageSnapshot? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CacheReadError.malformed
        }
        guard let root = JSONValue.object(parsed) else {
            throw CacheReadError.malformed
        }

        guard let rawEntry = root["cachedUsageUtilization"], !(rawEntry is NSNull) else {
            return nil
        }
        guard let entry = JSONValue.object(rawEntry) else {
            throw CacheReadError.malformed
        }

        let cachedAccount = JSONValue.nonEmptyString(entry["accountUuid"])
        let currentAccount = JSONValue.nonEmptyString(JSONValue.object(root["oauthAccount"])?["accountUuid"])
        if let cachedAccount, let currentAccount,
            cachedAccount.caseInsensitiveCompare(currentAccount) != .orderedSame
        {
            throw CacheReadError.accountMismatch
        }

        guard let fetchedAtMs = JSONValue.double(entry["fetchedAtMs"]), fetchedAtMs >= 0,
            let utilization = entry["utilization"]
        else {
            throw CacheReadError.malformed
        }
        let report: UsageReport
        do {
            report = try UsageResponseDecoder.decode(object: utilization)
        } catch {
            throw CacheReadError.malformed
        }

        let snapshot = UsageSnapshot(
            report: report,
            fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
            source: .claudeCodeCache
        )
        // A fetch time far in the future would look fresh until then and hide every real update.
        guard snapshot.hasPlausibleFetchDate(at: now) else {
            throw CacheReadError.malformed
        }
        return snapshot
    }
}
