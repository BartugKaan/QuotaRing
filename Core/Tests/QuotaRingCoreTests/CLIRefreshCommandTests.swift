import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct CLIRefreshCommandTests {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    @Test func argumentsAreExactlyTheVerifiedCommand() {
        #expect(
            CLIRefreshCommand.arguments == [
                "-p", "/usage", "--safe-mode", "--no-session-persistence", "--output-format", "json",
            ])
        #expect(CLIRefreshCommand.versionArguments == ["--version"])
    }

    @Test func limitsMatchTheSpecification() {
        #expect(CLIRefreshCommand.timeout == 30)
        #expect(CLIRefreshCommand.versionTimeout == 10)
        #expect(CLIRefreshCommand.maxOutputBytes == 256 * 1024)
    }

    @Test func environmentIsMinimalAndTurnsOffUpdatesAndReporting() {
        let environment = CLIRefreshCommand.environment(
            home: home, user: "test", lang: "tr_TR.UTF-8",
            binaryDirectory: URL(fileURLWithPath: "/Users/test/.npm-global/bin", isDirectory: true),
            customConfigDirectory: nil)
        #expect(
            environment == [
                "HOME": "/Users/test",
                "USER": "test",
                "LOGNAME": "test",
                "LANG": "tr_TR.UTF-8",
                "PATH": "/Users/test/.npm-global/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                "DISABLE_AUTOUPDATER": "1",
                "DISABLE_TELEMETRY": "1",
                "DISABLE_ERROR_REPORTING": "1",
            ])
    }

    @Test func customConfigDirectoryIsPassedOn() {
        let environment = CLIRefreshCommand.environment(
            home: URL(fileURLWithPath: "/Users/test/", isDirectory: true), user: "test", lang: nil,
            binaryDirectory: URL(fileURLWithPath: "/opt/homebrew/bin/", isDirectory: true),
            customConfigDirectory: URL(fileURLWithPath: "/Users/test/work-claude/", isDirectory: true))
        #expect(
            environment == [
                "HOME": "/Users/test",
                "USER": "test",
                "LOGNAME": "test",
                "LANG": "en_US.UTF-8",
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                "DISABLE_AUTOUPDATER": "1",
                "DISABLE_TELEMETRY": "1",
                "DISABLE_ERROR_REPORTING": "1",
                "CLAUDE_CONFIG_DIR": "/Users/test/work-claude",
            ])
    }

    @Test func emptyLanguageFallsBackToEnglish() {
        let environment = CLIRefreshCommand.environment(
            home: home, user: "test", lang: "", binaryDirectory: URL(fileURLWithPath: "/usr/local/bin"),
            customConfigDirectory: nil)
        #expect(environment["LANG"] == "en_US.UTF-8")
    }

    @Test func nonessentialTrafficIsNeverDisabled() {
        // Verified on the owner's Mac: with CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, `/usage` answers from the stale
        // cache without asking Anthropic, so the whole run would be pointless.
        for custom in [nil, URL(fileURLWithPath: "/Users/test/work-claude")] {
            let environment = CLIRefreshCommand.environment(
                home: home, user: "test", lang: nil, binaryDirectory: URL(fileURLWithPath: "/usr/local/bin"),
                customConfigDirectory: custom)
            #expect(environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == nil)
            #expect(!environment.keys.contains { $0.contains("NONESSENTIAL") })
            #expect(environment["DISABLE_AUTOUPDATER"] == "1")
            #expect(environment["DISABLE_TELEMETRY"] == "1")
            #expect(environment["DISABLE_ERROR_REPORTING"] == "1")
        }
    }

    @Test func theSwitchedOffFeaturesAreTheOnesShown() {
        #expect(
            CLIRefreshCommand.switchedOffFeatures.map { "\($0.name)=\($0.value)" } == [
                "DISABLE_AUTOUPDATER=1", "DISABLE_TELEMETRY=1", "DISABLE_ERROR_REPORTING=1",
            ])
    }

    @Test func helpAndVersionLimits() {
        #expect(CLIRefreshCommand.helpArguments == ["--help"])
        #expect(CLIRefreshCommand.requiredFlags == ["--safe-mode", "--no-session-persistence"])
    }
}
