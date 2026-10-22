import Darwin
import Foundation

/// Why a file cannot be used as Claude Code's command-line tool.
///
/// The cases carry no payload: they are shown in Settings and written to logs by name only.
public enum CLIValidationError: Error, Equatable, Sendable {
    /// Nothing is there, or a symbolic link points to nothing.
    case missing
    /// It is a directory or a special file, not a regular file.
    case notAFile
    /// The current user cannot execute it.
    case notExecutable
    /// It belongs to someone other than the current user or root.
    case untrustedOwner
    /// Its group or other users may change it (`mode & 0o022 != 0`).
    case writableByOthers
    /// It could not be inspected for another reason (permissions on a parent folder, an I/O error).
    case unreadable
}

/// What identifies one version of a file on disk: when any of these change, it is a different binary (for example after
/// an update that replaced the file in place).
public struct CLIFileIdentity: Hashable, Sendable {
    public var path: String
    public var device: Int64
    public var inode: UInt64
    public var size: Int64
    public var modifiedNanoseconds: Int64

    public init(path: String, device: Int64, inode: UInt64, size: Int64, modifiedNanoseconds: Int64) {
        self.path = path
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedNanoseconds = modifiedNanoseconds
    }
}

/// A command-line tool that passed ``ClaudeCLILocator/validate(_:)``.
public struct CLIExecutable: Equatable, Sendable {
    /// The path as found or chosen, before symbolic links are followed (for example `~/.local/bin/claude`). Its folder
    /// goes first on the tool's `PATH`, because tools installed next to it (such as `node`) live there.
    public var path: URL
    /// The file that is executed: `path` with every symbolic link resolved.
    public var executable: URL
    /// The resolved file's identity when it was validated.
    public var identity: CLIFileIdentity

    public init(path: URL, executable: URL, identity: CLIFileIdentity) {
        self.path = path
        self.executable = executable
        self.identity = identity
    }
}

/// Every candidate that may be executed, in order, and why the user's own choice was skipped, if it was.
public struct CLISearch: Equatable, Sendable {
    /// Distinct files (by resolved path) that passed ``ClaudeCLILocator/inspect(_:)``, in candidate order.
    public var executables: [CLIExecutable]
    /// Why the path chosen in Settings cannot be used; `nil` when none is chosen or it is fine.
    public var customPathProblem: CLIValidationError?

    public init(executables: [CLIExecutable], customPathProblem: CLIValidationError?) {
        self.executables = executables
        self.customPathProblem = customPathProblem
    }
}

/// The result of looking for the tool: the first usable candidate, and why the user's own choice was skipped, if it
/// was.
public struct CLILocation: Equatable, Sendable {
    public var executable: CLIExecutable?
    /// Why the path chosen in Settings cannot be used; `nil` when none is chosen or it is fine.
    public var customPathProblem: CLIValidationError?

    public init(executable: CLIExecutable?, customPathProblem: CLIValidationError?) {
        self.executable = executable
        self.customPathProblem = customPathProblem
    }
}

/// Finds Claude Code's `claude` command-line tool and decides whether a file may be executed as it.
///
/// Apps started from Finder or at login do not see the shell's `PATH`, so the tool is looked for in a fixed list of the
/// places its installers use. A file is only ever executed after ``validate(_:)`` accepted it. Nothing here executes
/// anything; it only inspects file metadata.
public enum ClaudeCLILocator {
    /// The places to look for `claude`, in order: the user's own choice; the Claude Code builds bundled with the Claude
    /// desktop app, newest version first (see ``desktopAppTools(home:)``); the native installer (`~/.local/bin`), the
    /// old local install (`~/.claude/local`), npm with a user prefix (`~/.npm-global/bin`), and Homebrew or npm with
    /// the default prefix (`/opt/homebrew/bin`, `/usr/local/bin`).
    ///
    /// Only the desktop app's folder is listed on disk to find its builds; nothing is executed.
    public static func candidates(home: URL, customPath: URL?) -> [URL] {
        let homePath = standardizedPath(home.path)
        var result: [URL] = []
        if let customPath {
            result.append(URL(fileURLWithPath: standardizedPath(customPath.path), isDirectory: false))
        }
        result += desktopAppTools(home: home)
        for relative in [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude"] {
            result.append(URL(fileURLWithPath: standardizedPath(homePath + "/" + relative), isDirectory: false))
        }
        result.append(URL(fileURLWithPath: "/opt/homebrew/bin/claude", isDirectory: false))
        result.append(URL(fileURLWithPath: "/usr/local/bin/claude", isDirectory: false))
        return result
    }

    /// The Claude Code builds the Claude desktop app keeps for itself:
    /// `<home>/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude`,
    /// newest version first (compared numerically), builds of one version by folder name. Folders whose name is not a
    /// version number are ignored. Only folder listings are read.
    public static func desktopAppTools(home: URL) -> [URL] {
        let root = standardizedPath(home.path) + "/" + desktopAppToolsFolder
        let fileManager = FileManager.default
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        let sorted = versions.filter(isVersionNumber).sorted { compareVersions($0, $1) == .orderedDescending }
        var result: [URL] = []
        for version in sorted {
            let versionPath = root + "/" + version
            guard let builds = try? fileManager.contentsOfDirectory(atPath: versionPath) else { continue }
            for build in builds.filter({ !$0.hasPrefix(".") }).sorted() {
                result.append(
                    URL(fileURLWithPath: versionPath + "/" + build + "/" + desktopAppToolSuffix, isDirectory: false))
            }
        }
        return result
    }

    /// The version folder of a tool inside the Claude desktop app's bundled Claude Code builds (for example `2.1.308`),
    /// or `nil` when `path` is not one. Decided from the path alone.
    public static func desktopAppVersion(of path: URL) -> String? {
        let components = standardizedPath(path.path).split(separator: "/").map(String.init)
        let folder = desktopAppToolsFolder.split(separator: "/").map(String.init)
        let suffix = desktopAppToolSuffix.split(separator: "/").map(String.init)
        // …/<folder…>/<version>/<build>/<suffix…>
        guard components.count >= folder.count + 2 + suffix.count, Array(components.suffix(suffix.count)) == suffix
        else { return nil }
        let versionIndex = components.count - suffix.count - 2
        guard Array(components[(versionIndex - folder.count)..<versionIndex]) == folder else { return nil }
        let version = components[versionIndex]
        return isVersionNumber(version) ? version : nil
    }

    /// Whether `text` is a plain version number: digits separated by single dots, such as `2.1.308`.
    public static func isVersionNumber(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 32 else { return false }
        return text.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// Compares two version numbers part by part as integers; a missing part counts as 0 (`2.1` equals `2.1.0`).
    public static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Every candidate that passes ``inspect(_:)``, each resolved file once, in order.
    public static func search(candidates: [URL], customPath: URL?) -> CLISearch {
        var customPathProblem: CLIValidationError?
        let custom = customPath.map { standardizedPath($0.path) }
        var executables: [CLIExecutable] = []
        var seen = Set<String>()
        for candidate in candidates {
            switch inspect(candidate) {
            case .success(let executable):
                if seen.insert(executable.executable.path).inserted {
                    executables.append(executable)
                }
            case .failure(let error):
                if standardizedPath(candidate.path) == custom, customPathProblem == nil {
                    customPathProblem = error
                }
            }
        }
        return CLISearch(executables: executables, customPathProblem: customPathProblem)
    }

    /// The first candidate that passes ``inspect(_:)``.
    public static func locate(candidates: [URL], customPath: URL?) -> CLILocation {
        let search = search(candidates: candidates, customPath: customPath)
        return CLILocation(executable: search.executables.first, customPathProblem: search.customPathProblem)
    }

    /// The file `url` resolves to, when it may be executed as Claude Code's tool.
    ///
    /// Symbolic links are followed. The target must be a regular file the current user can execute, owned by the
    /// current user or by root, whose permission bits do not let its group or others write it (`mode & 0o022 == 0`).
    /// Only the file's owner and permission bits are checked: access control lists and the permissions of the folders
    /// above it are not, so another account that can write to such a folder could still replace the file.
    public static func validate(_ url: URL) -> Result<URL, CLIValidationError> {
        inspect(url).map(\.executable)
    }

    /// Like ``validate(_:)``, also returning the path as given and the file's identity.
    public static func inspect(_ url: URL) -> Result<CLIExecutable, CLIValidationError> {
        guard url.isFileURL, url.path.hasPrefix("/") else { return .failure(.missing) }
        let path = standardizedPath(url.path)

        guard let resolvedPointer = realpath(path, nil) else {
            switch errno {
            case ENOENT, ENOTDIR: return .failure(.missing)
            default: return .failure(.unreadable)
            }
        }
        let resolved = String(cString: resolvedPointer)
        free(resolvedPointer)

        var info = stat()
        // `realpath` already followed every link; `lstat` makes sure the result is not a link swapped in since.
        guard lstat(resolved, &info) == 0 else {
            return .failure(errno == ENOENT ? .missing : .unreadable)
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notAFile) }
        guard info.st_uid == getuid() || info.st_uid == 0 else { return .failure(.untrustedOwner) }
        guard info.st_mode & 0o022 == 0 else { return .failure(.writableByOthers) }
        guard access(resolved, X_OK) == 0 else { return .failure(.notExecutable) }

        let modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        let identity = CLIFileIdentity(
            path: resolved,
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedNanoseconds: modified
        )
        return .success(
            CLIExecutable(
                path: URL(fileURLWithPath: path, isDirectory: false),
                executable: URL(fileURLWithPath: resolved, isDirectory: false),
                identity: identity))
    }

    private static let desktopAppToolsFolder = "Library/Application Support/Claude/claude-code"
    private static let desktopAppToolSuffix = "claude.app/Contents/MacOS/claude"

    /// `path` with `.` and `..` resolved and repeated or trailing slashes removed, without touching the file system.
    /// (`URL.standardizedFileURL` would also drop a leading `/private`, which changes the path's identity.)
    static func standardizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// What a file can do, from its `--version` and `--help` output: Claude Code that knows every option of
    /// ``CLIRefreshCommand/requiredFlags``, Claude Code too old for them, or something else.
    public static func capability(versionOutput: String, helpOutput: String) -> CLIVersionCheck {
        guard isClaudeCode(versionOutput: versionOutput) else { return .notClaudeCode }
        let version = version(fromVersionOutput: versionOutput)
        let knowsEveryFlag = CLIRefreshCommand.requiredFlags.allSatisfy { helpOutput.contains($0) }
        return knowsEveryFlag ? .claudeCode(version: version) : .unsupported(version: version)
    }

    /// Whether `claude --version` printed Claude Code's signature, for example `2.1.287 (Claude Code)`.
    public static func isClaudeCode(versionOutput: String) -> Bool {
        versionOutput.contains("(Claude Code)")
    }

    /// The version number from `claude --version` output, for example `2.1.287`; `nil` when the output is not Claude
    /// Code's or holds no plausible version. At most 32 characters of digits, letters, `.`, `-` and `+`.
    public static func version(fromVersionOutput output: String) -> String? {
        guard isClaudeCode(versionOutput: output) else { return nil }
        let line = output.split(whereSeparator: \.isNewline).first { $0.contains("(Claude Code)") } ?? ""
        let token = line.split(separator: " ").first.map(String.init) ?? ""
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+"))
        guard
            !token.isEmpty, token.count <= 32, token.first?.isNumber == true,
            token.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
        else { return nil }
        return token
    }
}
