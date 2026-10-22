import Foundation
import QuotaRingCore
import Testing

/// Everything one test is allowed to touch: a folder in the system's temporary directory and, inside it, a
/// preferences file of its own. Nothing here reaches the real preferences of QuotaRing, `~/.claude`, `~/.claude.json`,
/// the Keychain or the network, and `remove()` deletes it all.
///
/// The preferences are a suite named by a path: `UserDefaults` saves such a suite to that file. A plain name would leave
/// a new plist in `~/Library/Preferences` for every test.
@MainActor
final class TestSandbox {
    /// The folder of this test; the preferences file and every file the test writes are inside it.
    let directory: URL
    /// The suite name, which is also the name of the persistent domain (see ``makeSettings()``).
    let suite: String
    let defaults: UserDefaults

    init() throws {
        let base = FileManager.default.temporaryDirectory
        let name = "QuotaRingAppTests-" + UUID().uuidString
        // Resolved, so paths read back from the file system compare equal to the ones the test built.
        let resolved = base.resolvingSymlinksInPath().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)
        directory = resolved
        suite = resolved.appendingPathComponent("preferences", isDirectory: false).path
        // Belt and braces: a suite that is not a path inside the temporary folder could be the real one.
        try #require(suite.hasPrefix("/") && suite.contains("QuotaRingAppTests-"))
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    /// A store on this sandbox's preferences. Always passes the persistent domain explicitly: the default is the
    /// bundle identifier of the process, which for a test run is not QuotaRing's but must never be relied on.
    func makeSettings() -> SettingsStore {
        SettingsStore(defaults: defaults, persistentDomain: suite)
    }

    /// The values saved in this sandbox's preferences, as `SettingsStore` reads its consent settings.
    var savedValues: [String: Any] {
        defaults.persistentDomain(forName: suite) ?? [:]
    }

    /// Writes a file below the sandbox folder (creating folders as needed) and returns its URL.
    @discardableResult
    func write(_ relativePath: String, _ text: String, mode: Int = 0o600) throws -> URL {
        let url = directory.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    /// A folder below the sandbox folder.
    @discardableResult
    func folder(_ relativePath: String) throws -> URL {
        let url = directory.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Deletes the folder and what the preferences suite holds. Call it with `defer` right after creating the sandbox.
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Waits, without blocking the main actor, until `condition` holds: for work that finishes on its own queue or in a
/// `Task`. Returns whether it held before `timeout`.
@MainActor
func eventually(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// The two accounts of the file fixtures.
enum TestAccounts {
    static let a = "00000000-0000-4000-8000-0000000000a1"
    static let b = "00000000-0000-4000-8000-0000000000b2"
}

extension TestSandbox {
    /// A config directory for the engine and the model: Claude Code's data is looked for here and nowhere else.
    func claudeConfigDirectory() throws -> URL {
        try folder("claude-config")
    }

    /// Writes Claude Code's `.claude.json` into `configDirectory` with a session limit and a weekly limit.
    func writeClaudeJSON(
        in configDirectory: URL, fetchedAt: Date, sessionUsed: Double, resetsAt: Date,
        cacheAccount: String = TestAccounts.a, signedInAccount: String = TestAccounts.a
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let root: [String: Any] = [
            "oauthAccount": ["accountUuid": signedInAccount],
            "cachedUsageUtilization": [
                "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
                "accountUuid": cacheAccount,
                "utilization": [
                    "five_hour": ["utilization": sessionUsed, "resets_at": formatter.string(from: resetsAt)],
                    "seven_day": [
                        "utilization": 18.0, "resets_at": formatter.string(from: resetsAt.addingTimeInterval(86_400)),
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: root).write(
            to: configDirectory.appendingPathComponent(".claude.json"))
    }

    /// One assistant line of a transcript, written below `configDirectory/projects`.
    func writeTranscript(
        in configDirectory: URL, at timestamp: Date, input: Int, output: Int, project: String = "alpha"
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line =
            "{\"type\":\"assistant\",\"timestamp\":\"\(formatter.string(from: timestamp))\","
            + "\"cwd\":\"/Users/test/dev/\(project)\",\"requestId\":\"req_TEST1\",\"message\":{\"id\":\"msg_TEST1\","
            + "\"role\":\"assistant\",\"model\":\"claude-opus-4-8\",\"usage\":{\"input_tokens\":\(input),"
            + "\"output_tokens\":\(output),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}\n"
        let url = configDirectory.appendingPathComponent("projects/-p/session.jsonl")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(line.utf8).write(to: url)
    }
}
