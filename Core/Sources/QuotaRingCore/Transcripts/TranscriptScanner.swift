import Darwin
import Foundation

/// Reads Claude Code's local JSONL transcripts and reports where tokens went.
///
/// The transcripts are append-only logs that Claude Code writes while the scanner reads them, and one response is
/// logged once per content block (and again in resumed sessions and sub-agent files). The scanner therefore:
///
/// - lists the tree once per scan (`readdir` and one `fstatat` per file) and opens only the files that need it: a file
///   whose device, inode, size and modification time are what the last pass left is not opened at all;
/// - never opens a file last modified before the retention window: a log is append-only, so none of its lines can be
///   newer than its modification time. Such a file is forgotten, and it is the bulk of a long history;
/// - keeps, for every file, the offset just past the last newline it has processed and parses only the bytes that
///   were appended since; a trailing line without a newline yet is left for the next scan;
/// - detects truncation (size below the offset) and replacement (different inode, or a modification time older than
///   the recorded one) and then re-reads that file from the start, replacing its entries;
/// - skips a line longer than `maxLineBytes` without buffering it, even while that line is still being written;
/// - merges lines with the same `TranscriptEntry.dedupeKey`, within a file and across files;
/// - never keeps an entry older than `retention` (8 days by default: the 7-day chart plus a session window), so
///   memory stays bounded however much history the transcripts hold. Such a line is dropped as soon as it is parsed;
/// - drains the Foundation objects a chunk creates before it reads the next one, so that the memory of a scan follows
///   the size of a chunk, not the number of bytes read;
/// - stops at the next file or chunk when the task that runs it is cancelled, and continues from there next time.
///
/// Symbolic links below the projects directory are never followed.
public actor TranscriptScanner {
    /// How long entries are kept by default: longer than the oldest range the app shows (7 local days).
    public static let defaultRetention: TimeInterval = 8 * 86_400

    /// The deepest directory level that is listed (below the projects directory); deeper ones are ignored. Claude Code
    /// nests three or four levels (`<project>/<session>/subagents`); the bound keeps open descriptors few.
    private static let maxDirectoryDepth = 32

    private let projectsDirectory: URL
    private let maxLineBytes: Int
    private let readChunkSize: Int
    private let retention: TimeInterval
    /// Whether the scan has been asked to stop. Tests replace it to cancel at an exact point.
    private let isCancelled: @Sendable () -> Bool

    private var files: [String: FileState] = [:]
    /// The merged result of the last scan; `nil` when a file changed since.
    private var mergedEntries: [TranscriptEntry]?

    /// How many files the most recent scan opened. A tree where nothing changed opens none, one that gained a few
    /// lines opens just the files that hold them. For diagnostics and tests.
    public private(set) var filesOpenedByLastScan = 0

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

    /// `readChunkSize` is exposed to tests so that small chunks can exercise lines that straddle reads, and
    /// `isCancelled` so that a test can cancel a scan at a chosen point.
    init(
        projectsDirectory: URL,
        maxLineBytes: Int,
        readChunkSize: Int,
        retention: TimeInterval = TranscriptScanner.defaultRetention,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.projectsDirectory = projectsDirectory
        self.maxLineBytes = max(1, maxLineBytes)
        self.readChunkSize = max(1, readChunkSize)
        self.retention = retention.isNaN ? Self.defaultRetention : max(0, retention)
        self.isCancelled = isCancelled
    }

    /// Brings every transcript up to date and returns each response of the last `retention` seconds before `now` once,
    /// oldest first. Older entries are forgotten, also by later scans.
    ///
    /// When the calling task is cancelled the scan stops at the next file or chunk and returns what it has so far,
    /// which may be incomplete: the caller is expected to discard it. What was read is kept, and the next scan goes on
    /// from there.
    public func scan(now: Date = Date()) -> [TranscriptEntry] {
        filesOpenedByLastScan = 0
        let cutoff = now.addingTimeInterval(-retention)

        // A listing cut short by a cancellation says nothing about which files are gone, so nothing is forgotten.
        guard let listing = Self.listTranscripts(under: projectsDirectory, isCancelled: isCancelled) else {
            return mergedEntries ?? mergeFiles(inOrder: files.keys.sorted())
        }
        defer { listing.close() }

        let present = Set(listing.files.map(\.path))
        for path in Array(files.keys) where !present.contains(path) {
            files[path] = nil
            mergedEntries = nil
        }
        for file in listing.files {
            guard !isCancelled(), refresh(file, below: listing.root, cutoff: cutoff) else { break }
        }
        dropEntries(before: cutoff)

        // Also after a cancellation: this is the merge of what `files` holds, and whatever a later scan reads changes
        // that and clears it.
        if let mergedEntries { return mergedEntries }
        let merged = mergeFiles(inOrder: listing.files.map(\.path))
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
        /// Whether the last pass went on to the end of the file. A pass that ended early (a read error, a
        /// cancellation) leaves this `false`, and the file is opened again even when it has not changed since.
        var isFullyRead = false
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

    /// What `stat` says about a file: from `fstat` on an open descriptor, or from `fstatat` when listing.
    private struct FileIdentity: Equatable {
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

        /// The modification time as a `Date`, for comparing with the retention cutoff.
        var modificationDate: Date {
            Date(timeIntervalSince1970: TimeInterval(modificationNanoseconds) / 1e9)
        }
    }

    /// A transcript found by the directory walk.
    private struct ListedFile {
        /// The absolute path: the key of the file's state. Files are not opened by it (see ``relativePath``).
        var path: String
        /// The path below the projects directory, such as `-Users-me-project/session.jsonl`.
        var relativePath: String
        var identity: FileIdentity
    }

    /// What the directory walk found, and the open projects directory the files are reached from.
    private struct Listing {
        var files: [ListedFile]
        /// A descriptor of the projects directory, or -1 when it could not be opened. Files are opened relative to it,
        /// one component at a time without following links.
        var root: Int32

        func close() {
            if root >= 0 { Darwin.close(root) }
        }
    }

    /// Brings one listed file up to date. Returns `false` when it stopped early because the scan was cancelled.
    private func refresh(_ file: ListedFile, below root: Int32, cutoff: Date) -> Bool {
        // A log is append-only, so none of its lines is newer than its modification time: a file untouched since
        // before the cutoff holds nothing that is still wanted, and is not even opened.
        if file.identity.modificationDate < cutoff {
            if files.removeValue(forKey: file.path) != nil { mergedEntries = nil }
            return true
        }
        // Nothing happened to it since the last pass, and that pass read it to the end: nothing to read.
        if let known = files[file.path], known.isFullyRead, known.identity == file.identity {
            return true
        }

        guard let (handle, identity) = Self.openRegularFile(file.relativePath, below: root) else { return true }
        defer { try? handle.close() }
        filesOpenedByLastScan += 1

        // Taken out of `files` while it is worked on, so that recording entries mutates it in place.
        var state = files.removeValue(forKey: file.path) ?? FileState(identity: identity)
        if state.isOutdated(by: identity) {
            state = FileState(identity: identity)
            mergedEntries = nil
        }
        state.identity = identity
        state.isFullyRead = false
        defer { files[file.path] = state }

        guard identity.size > state.offset else {
            state.isFullyRead = true
            return true
        }

        var assembler = LineAssembler(
            maxLineBytes: maxLineBytes, offset: state.offset, isSkippingLine: state.isSkippingLine)
        var didChange = false
        var reachedEnd = false
        var wasCancelled = false
        do {
            try handle.seek(toOffset: state.offset)
            while true {
                if isCancelled() {
                    wasCancelled = true
                    break
                }
                // The pool is drained after every chunk: the chunk and the parsed JSON trees are autoreleased, and
                // without it they would pile up until the whole scan returns.
                let hasMore = try autoreleasepool { () throws -> Bool in
                    guard let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty else { return false }
                    assembler.feed(chunk) { line in
                        // A line older than the cutoff is not worth an entry that the next step would drop again.
                        guard let entry = TranscriptLineParser.parse(line), entry.timestamp >= cutoff else { return }
                        if state.record(entry) { didChange = true }
                    }
                    return true
                }
                if !hasMore {
                    reachedEnd = true
                    break
                }
            }
        } catch {
            // A read failure ends this pass. Everything before `assembler.committedOffset` was handled in full and
            // the rest is read again by the next scan.
        }
        state.offset = assembler.committedOffset
        state.isSkippingLine = assembler.isSkippingLine
        state.isFullyRead = reachedEnd
        if didChange { mergedEntries = nil }
        return !wasCancelled
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

    /// All `*.jsonl` regular files below `directory` with what `fstatat` says about each, sorted by path, or `nil` when
    /// `isCancelled` stopped the walk. Symbolic links are skipped, both to files and to directories; only `directory`
    /// itself may be a link. The caller closes the listing.
    ///
    /// One pass: every directory is read once and every transcript statted once, without Foundation objects. This is
    /// the only place a link is followed: `directory` is resolved and opened once, and that descriptor is the anchor
    /// of everything else. Each subdirectory is opened relative to its parent's descriptor with `O_NOFOLLOW`, and so is
    /// each file later (see ``openRegularFile(_:below:)``), so nothing below the anchor is reached through a link, also
    /// when a directory or file is swapped for one after it was listed.
    private static func listTranscripts(under directory: URL, isCancelled: () -> Bool) -> Listing? {
        let root = directory.resolvingSymlinksInPath().path
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return Listing(files: [], root: -1) }
        // The walk closes the descriptor it is given; the scan keeps another one for opening the files.
        let anchor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard anchor >= 0 else {
            close(descriptor)
            return Listing(files: [], root: -1)
        }

        var found: [ListedFile] = []
        guard
            collect(
                from: descriptor, path: root, relativePath: "", depth: 0, into: &found, isCancelled: isCancelled)
        else {
            close(anchor)
            return nil
        }
        found.sort { $0.path < $1.path }
        return Listing(files: found, root: anchor)
    }

    /// Adds the transcripts of one directory, then those of its subdirectories, to `found`. Takes over `descriptor`,
    /// which must be open on a directory, and closes it. Returns `false` when cancelled.
    private static func collect(
        from descriptor: Int32,
        path: String,
        relativePath: String,
        depth: Int,
        into found: inout [ListedFile],
        isCancelled: () -> Bool
    ) -> Bool {
        guard let stream = fdopendir(descriptor) else {
            close(descriptor)
            return true
        }
        defer { closedir(stream) }
        if isCancelled() { return false }
        guard depth <= maxDirectoryDepth else { return true }

        let directoryDescriptor = dirfd(stream)
        var subdirectories: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }

            var kind = Int32(entry.pointee.d_type)
            var info = stat()
            var hasInfo = false
            if kind == DT_UNKNOWN {
                // A file system that does not say what an entry is: ask, without following a link.
                guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                hasInfo = true
                switch info.st_mode & S_IFMT {
                case S_IFDIR: kind = Int32(DT_DIR)
                case S_IFREG: kind = Int32(DT_REG)
                default: continue
                }
            }
            switch kind {
            case Int32(DT_DIR):
                subdirectories.append(name)
            case Int32(DT_REG):
                guard isTranscriptName(name) else { continue }
                if !hasInfo {
                    guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                }
                guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                found.append(
                    ListedFile(
                        path: join(path, name), relativePath: join(relative: relativePath, name),
                        identity: FileIdentity(info)))
            default:
                // Links (also to files and directories), pipes, sockets and devices are never followed or opened.
                continue
            }
        }

        for name in subdirectories {
            let child = openat(directoryDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { continue }
            let completed = collect(
                from: child, path: join(path, name), relativePath: join(relative: relativePath, name),
                depth: depth + 1, into: &found, isCancelled: isCancelled)
            if !completed { return false }
        }
        return true
    }

    private static func isTranscriptName(_ name: String) -> Bool {
        name.hasSuffix(".jsonl") && name.utf8.count > ".jsonl".utf8.count
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    private static func join(relative directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    /// Opens the file at `relativePath` below the directory `root` read-only, and only if it is a regular file. Every
    /// component is opened relative to the descriptor of the one before it with `O_NOFOLLOW`, so a directory, or the
    /// file itself, that has been replaced by a symbolic link since it was listed makes the open fail instead of
    /// leading somewhere else. The identity is taken from the open descriptor so that it describes the bytes that will
    /// be read.
    private static func openRegularFile(_ relativePath: String, below root: Int32) -> (FileHandle, FileIdentity)? {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = components.last else { return nil }

        var directory = root
        var ownsDirectory = false
        defer { if ownsDirectory { close(directory) } }
        for component in components.dropLast() {
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if ownsDirectory { close(directory) }
            guard next >= 0 else {
                ownsDirectory = false
                return nil
            }
            directory = next
            ownsDirectory = true
        }

        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
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
