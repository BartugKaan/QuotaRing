import CryptoKit
import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct ClaudePathsTests {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    private func hashSuffix(of path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }

    @Test func pathsDefault() {
        let paths = ClaudePaths(homeDirectory: home)
        #expect(paths.configDirectory.path == "/Users/test/.claude")
        #expect(paths.globalConfigFile.path == "/Users/test/.claude.json")
        #expect(paths.projectsDirectory.path == "/Users/test/.claude/projects")
        #expect(paths.credentialsFile.path == "/Users/test/.claude/.credentials.json")
        #expect(
            paths.keychainServiceNames == [
                "Claude Code-credentials",
                "Claude Code-credentials-" + hashSuffix(of: "/Users/test/.claude"),
            ]
        )
        #expect(ClaudePaths(homeDirectory: home) == paths)
    }

    @Test func pathsCustom() {
        let custom = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        let paths = ClaudePaths(customConfigDirectory: custom, homeDirectory: home)
        #expect(paths.configDirectory.path == "/tmp/x")
        #expect(paths.globalConfigFile.path == "/tmp/x/.claude.json")
        #expect(paths.projectsDirectory.path == "/tmp/x/projects")
        #expect(paths.credentialsFile.path == "/tmp/x/.credentials.json")
        // A custom directory must not fall back to the plain item: that belongs to the default account.
        #expect(paths.keychainServiceNames == ["Claude Code-credentials-" + hashSuffix(of: "/tmp/x")])
        #expect(paths != ClaudePaths(homeDirectory: home))
    }

    @Test func defaultInitializerUsesTheCurrentUsersHome() {
        let paths = ClaudePaths()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(paths.globalConfigFile.path.hasSuffix("/.claude.json"))
        #expect(paths.configDirectory.path.hasSuffix("/.claude"))
        #expect(paths.configDirectory.path.hasPrefix(home))
    }

    @Test func hashedServiceName() throws {
        let withSlash = ClaudePaths(customConfigDirectory: URL(fileURLWithPath: "/tmp/x/", isDirectory: true))
        let without = ClaudePaths(customConfigDirectory: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        let expected = "Claude Code-credentials-" + hashSuffix(of: "/tmp/x")

        #expect(withSlash.keychainServiceNames == [expected])
        #expect(without.keychainServiceNames == [expected])

        let suffix = String(expected.dropFirst("Claude Code-credentials-".count))
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func hashedServiceNameStandardizesLexicallyAndNormalizesToNFC() {
        let expected = "Claude Code-credentials-" + hashSuffix(of: "/tmp/x")
        let dotted = ClaudePaths(customConfigDirectory: URL(fileURLWithPath: "/tmp/a/../x/./", isDirectory: true))
        #expect(dotted.keychainServiceNames == [expected])

        // Symlinks are not resolved: /tmp is a symlink to /private/tmp on macOS, and must hash as written.
        let viaSymlink = ClaudePaths(customConfigDirectory: URL(fileURLWithPath: "/private/tmp/x", isDirectory: true))
        #expect(viaSymlink.keychainServiceNames != [expected])

        let composed = "/tmp/caf\u{00E9}"
        let decomposed = "/tmp/cafe\u{0301}"
        let expectedNFC = "Claude Code-credentials-" + hashSuffix(of: composed)
        // Swift's `==` treats canonically equivalent strings as equal, so compare the scalars.
        #expect(Array(composed.unicodeScalars) != Array(decomposed.unicodeScalars))
        #expect(hashSuffix(of: composed) != hashSuffix(of: decomposed))
        #expect(
            ClaudePaths(customConfigDirectory: URL(fileURLWithPath: decomposed, isDirectory: true))
                .keychainServiceNames == [expectedNFC]
        )
        #expect(
            ClaudePaths(customConfigDirectory: URL(fileURLWithPath: composed, isDirectory: true))
                .keychainServiceNames == [expectedNFC]
        )
    }
}
