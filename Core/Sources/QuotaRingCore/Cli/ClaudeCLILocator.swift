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
    /// The places Claude Code's installers put `claude`, after the user's own choice: the native installer
    /// (`~/.local/bin`), the old local install (`~/.claude/local`), npm with a user prefix (`~/.npm-global/bin`), and
    /// Homebrew or npm with the default prefix (`/opt/homebrew/bin`, `/usr/local/bin`).
    public static func candidates(home: URL, customPath: URL?) -> [URL] {
        let homePath = standardizedPath(home.path)
        var result: [URL] = []
        if let customPath {
            result.append(URL(fileURLWithPath: standardizedPath(customPath.path), isDirectory: false))
        }
        for relative in [".local/bin/claude", ".claude/local/claude", ".npm-global/bin/claude"] {
            result.append(URL(fileURLWithPath: standardizedPath(homePath + "/" + relative), isDirectory: false))
        }
        result.append(URL(fileURLWithPath: "/opt/homebrew/bin/claude", isDirectory: false))
        result.append(URL(fileURLWithPath: "/usr/local/bin/claude", isDirectory: false))
        return result
    }

    /// The first candidate that passes ``inspect(_:)``.
    public static func locate(candidates: [URL], customPath: URL?) -> CLILocation {
        var customPathProblem: CLIValidationError?
        let custom = customPath.map { standardizedPath($0.path) }
        for candidate in candidates {
            switch inspect(candidate) {
            case .success(let executable):
                return CLILocation(executable: executable, customPathProblem: customPathProblem)
            case .failure(let error):
                if standardizedPath(candidate.path) == custom, customPathProblem == nil {
                    customPathProblem = error
                }
            }
        }
        return CLILocation(executable: nil, customPathProblem: customPathProblem)
    }

    /// The file `url` resolves to, when it may be executed as Claude Code's tool.
    ///
    /// Symbolic links are followed. The target must be a regular file the current user can execute, owned by the
    /// current user or by root, and not writable by its group or by others (`mode & 0o022 == 0`), so that no other
    /// account can change what QuotaRing runs.
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
