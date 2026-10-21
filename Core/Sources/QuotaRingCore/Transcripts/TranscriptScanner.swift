import Darwin
import Foundation

/// Reads Claude Code's local JSONL transcripts and reports where tokens went.
///
/// The transcripts are append-only logs that Claude Code writes while the scanner reads them, and one response is
/// logged once per content block (and again in resumed sessions and sub-agent files). The scanner therefore:
///
/// - keeps, for every file, the offset just past the last newline it has processed and parses only the bytes that
///   were appended since; a trailing line without a newline yet is left for the next scan;
/// - detects truncation (size below the offset) and replacement (different inode, or a modification time older than
///   the recorded one) and then re-reads that file from the start, replacing its entries;
/// - skips a line longer than `maxLineBytes` without buffering it, even while that line is still being written;
/// - merges lines with the same `TranscriptEntry.dedupeKey`, within a file and across files;
/// - forgets entries older than `retention` (8 days by default: the 7-day chart plus a session window), so memory stays
///   bounded however much history the transcripts hold.
///
/// Symbolic links below the projects directory are never followed.
public actor TranscriptScanner {
    /// How long entries are kept by default: longer than the oldest range the app shows (7 local days).
    public static let defaultRetention: TimeInterval = 8 * 86_400

    private let projectsDirectory: URL
    private let maxLineBytes: Int
    private let readChunkSize: Int
    private let retention: TimeInterval

    private var files: [String: FileState] = [:]
    /// The merged result of the last scan; `nil` when a file changed since.
    private var mergedEntries: [TranscriptEntry]?

    /// - Parameters:
    ///   - projectsDirectory: Claude Code's `projects` directory; it is searched recursively for `*.jsonl` files.
    ///   - maxLineBytes: Lines longer than this (without the newline) are ignored.
    ///   - retention: Entries more than this many seconds older than the scan's `now` are dropped.
    public init(
        projectsDirectory: URL,
        maxLineBytes: Int = 10_485_760,
        retention: TimeInterval = TranscriptScanner.defaultRetention
    ) {
        self.init(
            projectsDirectory: projectsDirectory, maxLineBytes: maxLineBytes, readChunkSize: 1 << 20,
            retention: retention)
    }

    /// `readChunkSize` is exposed to tests so that small chunks can exercise lines that straddle reads.
    init(
        projectsDirectory: URL,
        maxLineBytes: Int,
        readChunkSize: Int,
        retention: TimeInterval = TranscriptScanner.defaultRetention
    ) {
        self.projectsDirectory = projectsDirectory
        self.maxLineBytes = max(1, maxLineBytes)
        self.readChunkSize = max(1, readChunkSize)
        self.retention = retention.isNaN ? Self.defaultRetention : max(0, retention)
    }

    /// Brings every transcript up to date and returns each response of the last `retention` seconds before `now` once,
    /// oldest first. Older entries are forgotten, also by later scans.
    public func scan(now: Date = Date()) -> [TranscriptEntry] {
        let paths = Self.transcriptPaths(under: projectsDirectory)

        let present = Set(paths)
        for path in Array(files.keys) where !present.contains(path) {
            files[path] = nil
            mergedEntries = nil
        }
        for path in paths {
            refresh(path)
        }
        dropEntries(before: now.addingTimeInterval(-retention))

        if let mergedEntries { return mergedEntries }
        let merged = mergeFiles(inOrder: paths)
        mergedEntries = merged
        return merged
    }

    // MARK: - Per-file state

    private struct FileState {
        var identity: FileIdentity
        /// Everything before this offset has been processed (or is being skipped as part of an oversized line).
        var offset: UInt64 = 0
        /// Whether `offset` lies inside an oversized line whose end has not been seen yet.
        var isSkippingLine = false
        var entries: [String: TranscriptEntry] = [:]

        init(identity: FileIdentity) {
            self.identity = identity
        }

        /// Whether the file at the same path is no longer the one this state describes, or no longer holds the bytes
        /// before `offset`: another inode, a modification time older than the recorded one, or a smaller size.
        func isOutdated(by current: FileIdentity) -> Bool {
            current.device != identity.device
                || current.inode != identity.inode
                || current.modificationNanoseconds < identity.modificationNanoseconds
                || current.size < offset
        }

        /// Returns whether `entry` changed what this file holds.
        mutating func record(_ entry: TranscriptEntry) -> Bool {
            let updated = entries[entry.dedupeKey].map { $0.merged(with: entry) } ?? entry
            guard entries[entry.dedupeKey] != updated else { return false }
            entries[entry.dedupeKey] = updated
            return true
        }
    }

    /// What `fstat` says about an open file.
    private struct FileIdentity {
        var device: Int64
        var inode: UInt64
        var size: UInt64
        var modificationNanoseconds: Int64

        init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = UInt64(max(0, info.st_size))
            modificationNanoseconds =
                Int64(info.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(info.st_mtimespec.tv_nsec)
        }
    }

    private func refresh(_ path: String) {
        guard let (handle, identity) = Self.openRegularFile(atPath: path) else { return }
        defer { try? handle.close() }

        // Taken out of `files` while it is worked on, so that recording entries mutates it in place.
        var state = files.removeValue(forKey: path) ?? FileState(identity: identity)
        if state.isOutdated(by: identity) {
            state = FileState(identity: identity)
            mergedEntries = nil
        }
        state.identity = identity
        defer { files[path] = state }

        guard identity.size > state.offset else { return }

        var assembler = LineAssembler(
            maxLineBytes: maxLineBytes, offset: state.offset, isSkippingLine: state.isSkippingLine)
        var didChange = false
        do {
            try handle.seek(toOffset: state.offset)
            while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
                assembler.feed(chunk) { line in
                    if let entry = TranscriptLineParser.parse(line), state.record(entry) {
                        didChange = true
                    }
                }
            }
        } catch {
            // A read failure ends this pass. Everything before `assembler.committedOffset` was handled in full and
            // the rest is read again by the next scan.
        }
        state.offset = assembler.committedOffset
        state.isSkippingLine = assembler.isSkippingLine
        if didChange { mergedEntries = nil }
    }

    // MARK: - Retention

    /// Forgets every entry with a timestamp before `cutoff`. A file whose lines were already read is not read again, so
    /// a dropped entry stays dropped (unless the file is replaced, and then the next pass drops it again).
    private func dropEntries(before cutoff: Date) {
        for (path, state) in files where state.entries.values.contains(where: { $0.timestamp < cutoff }) {
            files[path]?.entries = state.entries.filter { $0.value.timestamp >= cutoff }
            mergedEntries = nil
        }
    }

    // MARK: - Merging

    /// Merges the per-file entries, visiting files in path order so that "first known project" is deterministic.
    private func mergeFiles(inOrder paths: [String]) -> [TranscriptEntry] {
        var merged: [String: TranscriptEntry] = [:]
        for path in paths {
            guard let state = files[path] else { continue }
            for (key, entry) in state.entries {
                merged[key] = merged[key].map { $0.merged(with: entry) } ?? entry
            }
        }
        return merged.values.sorted {
            $0.timestamp != $1.timestamp ? $0.timestamp < $1.timestamp : $0.dedupeKey < $1.dedupeKey
        }
    }

    // MARK: - File system

    /// The paths of all `*.jsonl` regular files below `directory`, sorted. Symbolic links are skipped, both to
    /// files and to directories; only `directory` itself may be a link.
    private static func transcriptPaths(under directory: URL) -> [String] {
        let root = directory.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        let wanted = Set(keys)

        var found: [String] = []
        var pending = [root]
        while let current = pending.popLast() {
            guard
                let children = try? FileManager.default.contentsOfDirectory(
                    at: current, includingPropertiesForKeys: keys, options: [])
            else { continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: wanted), values.isSymbolicLink != true else {
                    continue
                }
                if values.isDirectory == true {
                    pending.append(child)
                } else if values.isRegularFile == true, child.pathExtension == "jsonl" {
                    found.append(child.path)
                }
            }
        }
        return found.sorted()
    }

    /// Opens `path` read-only without following a symbolic link in its last component, and only if it is a regular
    /// file. The identity is taken from the open descriptor so that it describes the bytes that will be read.
    private static func openRegularFile(atPath path: String) -> (FileHandle, FileIdentity)? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            return nil
        }
        return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), FileIdentity(info))
    }
}

/// Splits a stream of chunks into lines without ever holding more than `maxLineBytes` of an unfinished line.
struct LineAssembler {
    let maxLineBytes: Int
    /// The file offset just past the last newline handled (or past everything read, while skipping a line). The next
    /// pass starts here.
    private(set) var committedOffset: UInt64
    /// Whether the line being read is over the limit and is being discarded up to its newline.
    private(set) var isSkippingLine: Bool

    /// The start of the current line, up to `maxLineBytes` of it.
    private var pending = Data()
    /// The file offset of the first byte of the next chunk.
    private var position: UInt64

    init(maxLineBytes: Int, offset: UInt64, isSkippingLine: Bool) {
        self.maxLineBytes = maxLineBytes
        self.committedOffset = offset
        self.isSkippingLine = isSkippingLine
        self.position = offset
    }

    /// Calls `handleLine` with every complete line in `chunk` (newline excluded) that is within the size limit.
    mutating func feed(_ chunk: Data, handleLine: (Data) -> Void) {
        let chunkCount = chunk.count
        chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var lineStart = 0
            while lineStart < chunkCount {
                let remaining = chunkCount - lineStart
                guard let newline = memchr(base + lineStart, 0x0A, remaining) else {
                    appendUnfinished(base + lineStart, count: remaining, chunkEnd: position + UInt64(chunkCount))
                    break
                }
                let lineEnd = base.distance(to: UnsafeRawPointer(newline))
                finishLine(base + lineStart, count: lineEnd - lineStart, handleLine: handleLine)
                committedOffset = position + UInt64(lineEnd + 1)
                lineStart = lineEnd + 1
            }
        }
        position += UInt64(chunkCount)
    }

    /// The tail of a chunk that has no newline: the line continues in the next chunk.
    private mutating func appendUnfinished(_ start: UnsafeRawPointer, count: Int, chunkEnd: UInt64) {
        if isSkippingLine {
            committedOffset = chunkEnd
        } else if pending.count + count > maxLineBytes {
            pending = Data()
            isSkippingLine = true
            committedOffset = chunkEnd
        } else {
            pending.append(start.assumingMemoryBound(to: UInt8.self), count: count)
        }
    }

    private mutating func finishLine(_ start: UnsafeRawPointer, count: Int, handleLine: (Data) -> Void) {
        defer { pending.removeAll(keepingCapacity: true) }
        if isSkippingLine {
            isSkippingLine = false
        } else if pending.count + count > maxLineBytes {
            return
        } else if pending.isEmpty {
            if count > 0 { handleLine(Data(bytes: start, count: count)) }
        } else {
            pending.append(start.assumingMemoryBound(to: UInt8.self), count: count)
            handleLine(pending)
        }
    }
}
