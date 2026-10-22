import Darwin
import Foundation
import Testing

@testable import QuotaRingCore

/// A scratch directory for fake tools, removed when the test ends. Paths are resolved (`/var` → `/private/var`), so
/// they compare equal to what the locator returns.
struct CLIScratchDirectory {
    let url: URL

    init(_ name: String = "QuotaRingCLITests") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // `realpath` like the locator (`resolvingSymlinksInPath` would drop the `/private` prefix).
        let pointer = try #require(realpath(base.path, nil))
        defer { free(pointer) }
        url = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func file(_ name: String, contents: String = "#!/bin/sh\nexit 0\n", mode: Int = 0o755) throws -> URL {
        let fileURL = url.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fileURL.path)
        return fileURL
    }

    @discardableResult
    func symlink(_ name: String, to destination: URL) throws -> URL {
        let linkURL = url.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createDirectory(
            at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: destination)
        return linkURL
    }
}

@Suite struct ClaudeCLILocatorTests {
    // MARK: - Candidates

    @Test func candidatesListTheChosenPathFirstThenTheInstallerLocations() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let custom = URL(fileURLWithPath: "/Applications/Tools/claude")
        #expect(
            ClaudeCLILocator.candidates(home: home, customPath: custom).map(\.path) == [
                "/Applications/Tools/claude",
                "/Users/test/.local/bin/claude",
                "/Users/test/.claude/local/claude",
                "/Users/test/.npm-global/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
    }

    @Test func candidatesWithoutAChoiceStartWithTheNativeInstaller() {
        let home = URL(fileURLWithPath: "/Users/test/", isDirectory: true)
        #expect(
            ClaudeCLILocator.candidates(home: home, customPath: nil).map(\.path) == [
                "/Users/test/.local/bin/claude",
                "/Users/test/.claude/local/claude",
                "/Users/test/.npm-global/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
    }

    // MARK: - Validation

    @Test func acceptsAnExecutableFileOfTheUser() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let tool = try scratch.file("claude", mode: 0o755)

        #expect(ClaudeCLILocator.validate(tool) == .success(tool))
        // Owner-only permissions are fine too.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        #expect(ClaudeCLILocator.validate(tool) == .success(tool))
    }

    @Test func acceptsAFileOwnedByRoot() {
        // A system tool: owned by root, 0755. Only inspected, never run.
        #expect(ClaudeCLILocator.validate(URL(fileURLWithPath: "/bin/sh")) == .success(URL(fileURLWithPath: "/bin/sh")))
    }

    @Test func rejectsAGroupWritableFile() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let tool = try scratch.file("claude", mode: 0o775)
        #expect(ClaudeCLILocator.validate(tool) == .failure(.writableByOthers))
    }

    @Test func rejectsAWorldWritableFile() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        for mode in [0o757, 0o777, 0o722] {
            let tool = try scratch.file("claude-\(mode)", mode: mode)
            #expect(ClaudeCLILocator.validate(tool) == .failure(.writableByOthers))
        }
    }

    @Test func rejectsAFileThatIsNotExecutable() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let tool = try scratch.file("claude", mode: 0o644)
        #expect(ClaudeCLILocator.validate(tool) == .failure(.notExecutable))
    }

    @Test func rejectsADirectory() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let directory = scratch.url.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(ClaudeCLILocator.validate(directory) == .failure(.notAFile))
    }

    @Test func rejectsAMissingFileAndADanglingSymlink() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let missing = scratch.url.appendingPathComponent("claude")
        #expect(ClaudeCLILocator.validate(missing) == .failure(.missing))

        let dangling = try scratch.symlink("bin/claude", to: scratch.url.appendingPathComponent("nowhere/claude"))
        #expect(ClaudeCLILocator.validate(dangling) == .failure(.missing))
    }

    @Test func followsASymlinkToAGoodFile() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let target = try scratch.file("versions/2.1.287/claude", mode: 0o755)
        let link = try scratch.symlink("bin/claude", to: target)

        #expect(ClaudeCLILocator.validate(link) == .success(target))
        let inspected = try ClaudeCLILocator.inspect(link).get()
        // The path as found is kept: its folder goes on PATH.
        #expect(inspected.path == link)
        #expect(inspected.executable == target)
        #expect(inspected.identity.path == target.path)
    }

    @Test func judgesTheSymlinkTargetNotTheLink() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let target = try scratch.file("lib/claude", mode: 0o777)
        let link = try scratch.symlink("bin/claude", to: target)
        #expect(ClaudeCLILocator.validate(link) == .failure(.writableByOthers))
    }

    @Test func identityChangesWhenTheFileIsReplaced() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let tool = try scratch.file("claude", contents: "#!/bin/sh\necho one\n")
        let before = try ClaudeCLILocator.inspect(tool).get().identity
        #expect(try ClaudeCLILocator.inspect(tool).get().identity == before)

        try scratch.file("claude", contents: "#!/bin/sh\necho a longer two\n")
        #expect(try ClaudeCLILocator.inspect(tool).get().identity != before)
    }

    // MARK: - Locating

    @Test func locateUsesTheFirstValidCandidateAndSaysWhyTheChoiceWasSkipped() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let chosen = try scratch.file("chosen/claude", mode: 0o644)
        let fallback = try scratch.file("fallback/claude", mode: 0o755)

        let location = ClaudeCLILocator.locate(candidates: [chosen, fallback], customPath: chosen)
        #expect(location.executable?.executable == fallback)
        #expect(location.customPathProblem == .notExecutable)

        let good = ClaudeCLILocator.locate(candidates: [fallback], customPath: nil)
        #expect(good.executable?.executable == fallback)
        #expect(good.customPathProblem == nil)
    }

    @Test func locateFindsNothing() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let location = ClaudeCLILocator.locate(
            candidates: [
                scratch.url.appendingPathComponent("a/claude"), scratch.url.appendingPathComponent("b/claude"),
            ],
            customPath: nil)
        #expect(location == CLILocation(executable: nil, customPathProblem: nil))
    }

    // MARK: - Version check

    @Test func recognizesClaudeCodesVersionOutput() {
        #expect(ClaudeCLILocator.isClaudeCode(versionOutput: "2.1.287 (Claude Code)\n"))
        #expect(!ClaudeCLILocator.isClaudeCode(versionOutput: "2.1.287\n"))
        #expect(!ClaudeCLILocator.isClaudeCode(versionOutput: ""))
        #expect(!ClaudeCLILocator.isClaudeCode(versionOutput: "claude 1.0 (Claude)"))
    }

    @Test func readsTheVersionNumber() {
        #expect(ClaudeCLILocator.version(fromVersionOutput: "2.1.287 (Claude Code)\n") == "2.1.287")
        #expect(ClaudeCLILocator.version(fromVersionOutput: "1.0.0-beta.2 (Claude Code)") == "1.0.0-beta.2")
        #expect(ClaudeCLILocator.version(fromVersionOutput: "2.1.287") == nil)
        #expect(ClaudeCLILocator.version(fromVersionOutput: "(Claude Code)") == nil)
        #expect(ClaudeCLILocator.version(fromVersionOutput: "v2; rm -rf (Claude Code)") == nil)
        #expect(
            ClaudeCLILocator.version(fromVersionOutput: String(repeating: "1", count: 40) + " (Claude Code)") == nil)
    }

    // MARK: - The Claude desktop app's bundled Claude Code

    private static let appToolSuffix = "claude.app/Contents/MacOS/claude"

    @Test func candidatesPutTheDesktopAppsBundledToolsNewestFirstAfterTheChoice() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let root = "home/Library/Application Support/Claude/claude-code"
        for version in ["2.1.304", "2.1.308", "2.1.99", "2.2"] {
            try scratch.file("\(root)/\(version)/a1b2c3/\(Self.appToolSuffix)")
        }
        // Not versions: ignored.
        try scratch.file("\(root)/garbage/a1b2c3/\(Self.appToolSuffix)")
        try scratch.file("\(root)/2.1.x/a1b2c3/\(Self.appToolSuffix)")
        try scratch.file("\(root)/.DS_Store", mode: 0o644)

        let home = scratch.url.appendingPathComponent("home", isDirectory: true)
        let custom = URL(fileURLWithPath: "/Applications/Tools/claude")
        let app = scratch.url.appendingPathComponent(root).path
        #expect(
            ClaudeCLILocator.candidates(home: home, customPath: custom).map(\.path) == [
                "/Applications/Tools/claude",
                "\(app)/2.2/a1b2c3/\(Self.appToolSuffix)",
                "\(app)/2.1.308/a1b2c3/\(Self.appToolSuffix)",
                "\(app)/2.1.304/a1b2c3/\(Self.appToolSuffix)",
                "\(app)/2.1.99/a1b2c3/\(Self.appToolSuffix)",
                home.path + "/.local/bin/claude",
                home.path + "/.claude/local/claude",
                home.path + "/.npm-global/bin/claude",
                "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude",
            ])
    }

    @Test func everyBuildFolderOfAVersionIsListed() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let root = "home/Library/Application Support/Claude/claude-code/2.1.308"
        try scratch.file("\(root)/bbbb/\(Self.appToolSuffix)")
        try scratch.file("\(root)/aaaa/\(Self.appToolSuffix)")

        let tools = ClaudeCLILocator.desktopAppTools(home: scratch.url.appendingPathComponent("home"))
        #expect(tools.map { $0.pathComponents.suffix(5).first } == ["aaaa", "bbbb"])
    }

    @Test func noDesktopAppMeansNoExtraCandidates() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        #expect(ClaudeCLILocator.desktopAppTools(home: scratch.url).isEmpty)
        #expect(ClaudeCLILocator.candidates(home: scratch.url, customPath: nil).count == 5)
    }

    @Test func versionsCompareNumerically() {
        #expect(ClaudeCLILocator.isVersionNumber("2.1.308"))
        #expect(ClaudeCLILocator.isVersionNumber("10"))
        #expect(!ClaudeCLILocator.isVersionNumber("garbage"))
        #expect(!ClaudeCLILocator.isVersionNumber("2.1.x"))
        #expect(!ClaudeCLILocator.isVersionNumber("2..1"))
        #expect(!ClaudeCLILocator.isVersionNumber(""))
        #expect(!ClaudeCLILocator.isVersionNumber(".2.1"))

        #expect(ClaudeCLILocator.compareVersions("2.1.308", "2.1.304") == .orderedDescending)
        #expect(ClaudeCLILocator.compareVersions("2.1.99", "2.1.304") == .orderedAscending)
        #expect(ClaudeCLILocator.compareVersions("2.2", "2.1.308") == .orderedDescending)
        #expect(ClaudeCLILocator.compareVersions("2.1", "2.1.0") == .orderedSame)
        #expect(ClaudeCLILocator.compareVersions("10.0", "9.9.9") == .orderedDescending)
    }

    @Test func recognizesTheDesktopAppsBundle() {
        let bundled = URL(
            fileURLWithPath:
                "/Users/test/Library/Application Support/Claude/claude-code/2.1.308/a1b2c3/claude.app/Contents/MacOS/claude"
        )
        #expect(ClaudeCLILocator.desktopAppVersion(of: bundled) == "2.1.308")
        #expect(ClaudeCLILocator.desktopAppVersion(of: URL(fileURLWithPath: "/usr/local/bin/claude")) == nil)
        #expect(
            ClaudeCLILocator.desktopAppVersion(
                of: URL(fileURLWithPath: "/Users/test/Library/Application Support/Claude/claude-code/x/a/claude"))
                == nil)
        #expect(
            ClaudeCLILocator.desktopAppVersion(
                of: URL(
                    fileURLWithPath:
                        "/Users/test/Library/Application Support/Claude/claude-code/garbage/a1/claude.app/Contents/MacOS/claude"
                )) == nil)
    }

    // MARK: - Capability

    private func fixtureText(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aCurrentClaudeCodeIsCapable() throws {
        #expect(
            ClaudeCLILocator.capability(
                versionOutput: "2.1.308 (Claude Code)\n", helpOutput: try fixtureText("cli-help-current"))
                == .claudeCode(version: "2.1.308"))
    }

    @Test func anOldClaudeCodeIsUnsupported() throws {
        // 1.0.113 has neither --safe-mode nor --no-session-persistence.
        #expect(
            ClaudeCLILocator.capability(
                versionOutput: "1.0.113 (Claude Code)\n", helpOutput: try fixtureText("cli-help-1.0.113"))
                == .unsupported(version: "1.0.113"))
        // Both flags are needed.
        #expect(
            ClaudeCLILocator.capability(versionOutput: "2.0.0 (Claude Code)", helpOutput: "  --safe-mode   Safe")
                == .unsupported(version: "2.0.0"))
        #expect(
            ClaudeCLILocator.capability(versionOutput: "2.0.0 (Claude Code)", helpOutput: "")
                == .unsupported(version: "2.0.0"))
    }

    @Test func somethingElseIsNotClaudeCode() throws {
        #expect(
            ClaudeCLILocator.capability(versionOutput: "1.0.0\n", helpOutput: try fixtureText("cli-help-current"))
                == .notClaudeCode)
    }

    // MARK: - Search

    @Test func searchListsEveryUsableCandidateOnceInOrder() throws {
        let scratch = try CLIScratchDirectory()
        defer { scratch.remove() }
        let first = try scratch.file("a/claude")
        let bad = try scratch.file("b/claude", mode: 0o666)
        let second = try scratch.file("c/claude")
        let linkToFirst = try scratch.symlink("d/claude", to: first)

        let search = ClaudeCLILocator.search(candidates: [bad, first, linkToFirst, second], customPath: bad)
        #expect(search.executables.map(\.executable) == [first, second])
        #expect(search.customPathProblem == .writableByOthers)
    }
}
