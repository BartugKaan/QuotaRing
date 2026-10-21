import Darwin
import Foundation

/// Saves the last good usage snapshot so the menu bar is meaningful right after launch.
///
/// - Only the usage report is written, with when and from which source it was fetched: the limits (percentages, reset
///   times and metadata such as kind, group, scope name, severity and whether active), the weekly breakdown, and
///   whether extra usage is on with its percentage. No token, and no extra-usage money amounts.
/// - Each file records the Claude config directory it was read from. ``load(configDirectory:)`` returns nothing for
///   any other directory, because another directory can belong to another account.
/// - The directory is private to the user (0700). The file is 0600 from the moment it exists: it is written to a
///   private temporary file that is then renamed over the target, which is atomic.
/// - Loading accepts only a regular file of at most ``maxFileSize`` bytes. A symbolic link is ignored.
///
/// Methods run synchronously; callers serialize them (the app uses one queue, so a delete lands after any pending
/// save).
public struct LastSnapshotStore: Sendable {
    /// Version 1 had no config directory and is ignored.
    public static let formatVersion = 2
    public static let maxFileSize = 1_048_576

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/QuotaRing/last-snapshot.json`.
    public static func standard() -> LastSnapshotStore? {
        guard
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = support.appendingPathComponent("QuotaRing", isDirectory: true)
        return LastSnapshotStore(fileURL: directory.appendingPathComponent("last-snapshot.json", isDirectory: false))
    }

    private struct Envelope: Codable {
        var version: Int
        var configDirectory: String
        var snapshot: UsageSnapshot
    }

    /// The saved snapshot, or `nil` when there is none, it was saved for another config directory, its fetch time lies
    /// more than ``UsageSnapshot/maxFutureSkew`` after `now`, or the file cannot be used.
    public func load(configDirectory: URL, now: Date = Date()) -> UsageSnapshot? {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maxFileSize,
            let data = try? Data(contentsOf: fileURL)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard
            let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.version == Self.formatVersion,
            envelope.configDirectory == Self.key(for: configDirectory),
            envelope.snapshot.hasPlausibleFetchDate(at: now)
        else { return nil }
        return envelope.snapshot
    }

    /// Writes `snapshot`, read from `configDirectory`, replacing any earlier file. Demo snapshots are never written.
    public func save(_ snapshot: UsageSnapshot, configDirectory: URL) throws {
        guard snapshot.source != .demo else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let envelope = Envelope(
            version: Self.formatVersion,
            configDirectory: Self.key(for: configDirectory),
            snapshot: Self.stripped(snapshot)
        )
        let data = try encoder.encode(envelope)

        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporary = directory.appendingPathComponent(".last-snapshot-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// Removes the saved snapshot, if any.
    public func delete() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    /// The directory as stored in the file: absolute, without `.`/`..` components or a trailing slash.
    private static func key(for configDirectory: URL) -> String {
        configDirectory.standardizedFileURL.path
    }

    private static func stripped(_ snapshot: UsageSnapshot) -> UsageSnapshot {
        var copy = snapshot
        if let extra = copy.report.extraUsage {
            copy.report.extraUsage = ExtraUsage(isEnabled: extra.isEnabled, percentUsed: extra.percentUsed)
        }
        return copy
    }
}
