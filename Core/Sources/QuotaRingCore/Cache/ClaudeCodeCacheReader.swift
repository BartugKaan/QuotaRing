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
    ///   `fetchedAtMs`, or a `utilization` the usage decoder cannot use), and ``CacheReadError/accountMismatch``
    ///   when the entry and `oauthAccount` both name an account and the two differ (the cache belongs to someone
    ///   else).
    public func read() throws -> UsageSnapshot? {
        let path = resolvedPath
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            if Self.isFileNotFound(error) { return nil }
            throw CacheReadError.unreadable
        }
        // Symlinks are already resolved, so anything but a regular file is a directory, FIFO, socket or device. Those
        // can block a read or report a size of 0 and so slip past the size cap.
        guard
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = Self.fingerprint(from: attributes)?.size
        else {
            throw CacheReadError.unreadable
        }
        guard size <= maxFileSize else {
            throw CacheReadError.fileTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        } catch {
            if Self.isFileNotFound(error) { return nil }
            throw CacheReadError.unreadable
        }
        // The file may have grown between the size check and the read.
        guard Int64(data.count) <= maxFileSize else {
            throw CacheReadError.fileTooLarge
        }

        return try Self.extractSnapshot(from: data)
    }

    // MARK: - Private

    /// `attributesOfItem` describes a symbolic link itself rather than its target, which would make both the size
    /// limit and the fingerprint meaningless for a symlinked `~/.claude.json` (a common dotfile-manager setup).
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

    private static func isFileNotFound(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
        }
        return false
    }

    /// Parses the document, keeps only the cache entry (and the account UUIDs needed to vet it) and lets the rest of
    /// the tree go out of scope. Parser errors are discarded because their descriptions can quote file contents.
    private static func extractSnapshot(from data: Data) throws -> UsageSnapshot? {
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

        return UsageSnapshot(
            report: report,
            fetchedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
            source: .claudeCodeCache
        )
    }
}
