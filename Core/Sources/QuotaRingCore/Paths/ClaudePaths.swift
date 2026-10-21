import CryptoKit
import Foundation

/// Locations of Claude Code's on-disk state and the Keychain service names it may use for credentials.
///
/// All values are derived purely from the configured config directory `D` and the home directory; nothing is read
/// from disk or the environment.
public struct ClaudePaths: Sendable, Equatable {
    /// `D`: `~/.claude` by default, or the custom directory.
    public var configDirectory: URL
    /// `~/.claude.json` by default; `D/.claude.json` for a custom directory.
    public var globalConfigFile: URL
    /// `D/projects`.
    public var projectsDirectory: URL
    /// `D/.credentials.json`.
    public var credentialsFile: URL
    /// Candidate Keychain generic-password service names in lookup order.
    ///
    /// With the default config directory: `Claude Code-credentials`, then
    /// `Claude Code-credentials-<first 8 hex of sha256(D)>`. With a custom config directory only the hashed name is
    /// listed, because the plain item belongs to the default account and reading it could show another account's
    /// usage.
    ///
    /// For the hash `D` is an absolute path, standardized lexically (`.`/`..`, repeated and trailing slashes),
    /// with symlinks left unresolved, and NFC-normalized.
    public var keychainServiceNames: [String]

    public init(
        customConfigDirectory: URL? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let directoryPath: String
        let globalConfigPath: String
        if let customConfigDirectory {
            directoryPath = Self.standardizedPath(customConfigDirectory.path)
            globalConfigPath = Self.join(directoryPath, ".claude.json")
        } else {
            let homePath = Self.standardizedPath(homeDirectory.path)
            directoryPath = Self.join(homePath, ".claude")
            globalConfigPath = Self.join(homePath, ".claude.json")
        }

        configDirectory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        globalConfigFile = URL(fileURLWithPath: globalConfigPath, isDirectory: false)
        projectsDirectory = URL(fileURLWithPath: Self.join(directoryPath, "projects"), isDirectory: true)
        credentialsFile = URL(fileURLWithPath: Self.join(directoryPath, ".credentials.json"), isDirectory: false)

        let baseServiceName = "Claude Code-credentials"
        let hashedServiceName = baseServiceName + "-" + Self.hashSuffix(of: directoryPath)
        if customConfigDirectory == nil {
            keychainServiceNames = [baseServiceName, hashedServiceName]
        } else {
            keychainServiceNames = [hashedServiceName]
        }
    }

    private static func hashSuffix(of path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func join(_ directory: String, _ component: String) -> String {
        directory == "/" ? "/" + component : directory + "/" + component
    }

    /// Resolves `.` and `..` components and collapses repeated and trailing slashes without touching the file system.
    private static func standardizedPath(_ path: String) -> String {
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
}
