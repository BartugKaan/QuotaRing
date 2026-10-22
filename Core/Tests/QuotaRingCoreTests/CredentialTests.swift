import CryptoKit
import Foundation
import Security
import Testing

@testable import QuotaRingCore

private let fakeAccessToken = "sk-ant-oat01-TEST-access-0123456789"

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func parse(json: String) throws -> OAuthCredential {
    try OAuthCredential.parse(Data(json.utf8))
}

/// The error `parse` throws for `data`, or `nil` if it succeeds.
private func parseError(_ data: Data) -> CredentialError? {
    do throws(CredentialError) {
        _ = try OAuthCredential.parse(data)
        return nil
    } catch {
        return error
    }
}

/// Every way a value can be rendered as text in a log line, crash report or debugger.
private func renderings(of value: Any) -> [String] {
    var dumped = ""
    dump(value, to: &dumped)
    var printed = ""
    print(value, to: &printed)
    var debugPrinted = ""
    debugPrint(value, to: &debugPrinted)
    var result = ["\(value)", String(describing: value), String(reflecting: value), dumped, printed, debugPrinted]
    if let error = value as? any Error {
        result.append(error.localizedDescription)
        result.append(String(describing: error as NSError))
    }
    return result
}

// MARK: - Parsing

@Suite struct CredentialParsingTests {
    @Test func parsesValid() throws {
        let credential = try OAuthCredential.parse(fixtureData("credentials-valid"))

        #expect(credential.accessToken.withValue { $0 } == fakeAccessToken)
        #expect(credential.expiresAt?.timeIntervalSince1970 == 1_792_605_287.037)
        #expect(credential.subscriptionType == "max")
        #expect(credential.rateLimitTier == "default_claude_max_5x")
    }

    @Test func mcpOnlyIsMissingClaudeAiOauth() throws {
        let data = try fixtureData("credentials-mcp-only")
        #expect(throws: CredentialError.missingClaudeAiOauth) { try OAuthCredential.parse(data) }

        #expect(throws: CredentialError.missingClaudeAiOauth) { try parse(json: "{}") }
        #expect(throws: CredentialError.missingClaudeAiOauth) { try parse(json: #"{"claudeAiOauth": null}"#) }
    }

    @Test func emptyTokenRejected() throws {
        let data = try fixtureData("credentials-empty-token")
        #expect(throws: CredentialError.emptyToken) { try OAuthCredential.parse(data) }

        #expect(throws: CredentialError.emptyToken) { try parse(json: #"{"claudeAiOauth": {}}"#) }
        #expect(throws: CredentialError.emptyToken) {
            try parse(json: #"{"claudeAiOauth": {"accessToken": null, "expiresAt": 1792605287037}}"#)
        }
    }

    @Test func malformedRejected() throws {
        let data = try fixtureData("credentials-malformed")
        #expect(throws: CredentialError.malformed) { try OAuthCredential.parse(data) }

        let malformed = [
            "",
            "not json",
            "[]",
            #""sk-ant-oat01-TEST""#,
            #"{"claudeAiOauth": "sk-ant-oat01-TEST"}"#,
            #"{"claudeAiOauth": ["sk-ant-oat01-TEST"]}"#,
            #"{"claudeAiOauth": {"accessToken": 42}}"#,
            #"{"claudeAiOauth": {"accessToken": ["sk-ant-oat01-TEST"]}}"#,
            #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-TEST", "expiresAt": "tomorrow"}}"#,
            #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-TEST", "expiresAt": true}}"#,
        ]
        for json in malformed {
            #expect(parseError(Data(json.utf8)) == .malformed, "\(json)")
        }
    }

    /// The token ends up in an HTTP header, so anything but visible ASCII (spaces, CR/LF, other control characters,
    /// non-ASCII) is refused rather than sent.
    @Test func tokenMustBeVisibleASCII() throws {
        let tokens = [
            "sk-ant-oat01-TEST\r\nX-Injected: 1",
            "sk-ant-oat01-TEST\n",
            " sk-ant-oat01-TEST",
            "sk-ant oat01-TEST",
            "sk-ant-oat01-TEST\t",
            "sk-ant-oat01-TEST\u{0}",
            "sk-ant-oat01-TEST\u{7F}",
            "sk-ant-oat01-TÉST",
            "   ",
        ]
        for token in tokens {
            let object = ["claudeAiOauth": ["accessToken": token]]
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(parseError(data) == .malformed, "\(token.debugDescription)")
        }
    }

    /// Only `accessToken`, `expiresAt`, `subscriptionType` and `rateLimitTier` are read, so unexpected shapes of
    /// every other key (notably `refreshToken` and `mcpOAuth`) cannot affect parsing.
    @Test func unrelatedKeysAreNeverDecoded() throws {
        let credential = try parse(
            json: #"""
                {
                  "claudeAiOauth": {
                    "accessToken": "sk-ant-oat01-TEST",
                    "refreshToken": {"unexpected": [1, 2, 3]},
                    "refreshTokenExpiresAt": "not a number",
                    "scopes": 7,
                    "somethingNew": null
                  },
                  "mcpOAuth": "unexpected",
                  "otherTopLevel": [true]
                }
                """#
        )
        #expect(credential.accessToken.withValue { $0 } == "sk-ant-oat01-TEST")
        #expect(credential.expiresAt == nil)
    }

    @Test func displayMetadataIsOptionalAndTolerant() throws {
        let minimal = try parse(json: #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-TEST"}}"#)
        #expect(minimal.expiresAt == nil)
        #expect(minimal.subscriptionType == nil)
        #expect(minimal.rateLimitTier == nil)

        let oddTypes = try parse(
            json: #"""
                {"claudeAiOauth": {"accessToken": "sk-ant-oat01-TEST", "expiresAt": null,
                  "subscriptionType": 5, "rateLimitTier": {"tier": "x"}}}
                """#
        )
        #expect(oddTypes.expiresAt == nil)
        #expect(oddTypes.subscriptionType == nil)
        #expect(oddTypes.rateLimitTier == nil)
    }

    @Test func expiresAtIsMillisecondsSinceEpoch() throws {
        // `Date` stores seconds since 2001, so values near 1970 lose a little precision; compare with a tolerance.
        let fractional = try parse(json: #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1500.5}}"#)
        #expect(abs((fractional.expiresAt?.timeIntervalSince1970 ?? .nan) - 1.5005) < 1e-6)

        let past = try parse(json: #"{"claudeAiOauth": {"accessToken": "t", "expiresAt": 1000}}"#)
        #expect(past.isExpired(now: Date(timeIntervalSince1970: 1_792_605_287)))
    }

    @Test func oversizedDataRejected() throws {
        let padding = String(repeating: "x", count: 1_048_576)
        let json = #"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-TEST"}, "padding": ""# + padding + #""}"#
        #expect(throws: CredentialError.malformed) { try parse(json: json) }
    }

    @Test func errorsNeverContainToken() throws {
        var errors: [CredentialError] = [
            .notFound, .malformed, .missingClaudeAiOauth, .emptyToken, .insecureFile, .keychain(errSecAuthFailed),
        ]
        // Errors produced from data that contains tokens must not capture any of it.
        for name in ["credentials-mcp-only", "credentials-empty-token", "credentials-malformed"] {
            errors.append(try #require(parseError(fixtureData(name))))
        }
        errors.append(try #require(parseError(Data(#"{"claudeAiOauth": {"accessToken": 1}}"#.utf8))))
        errors.append(
            try #require(parseError(Data(#"{"claudeAiOauth": {"accessToken": "sk-ant-oat01-TEST\n"}}"#.utf8)))
        )

        let credential = try OAuthCredential.parse(fixtureData("credentials-valid"))

        for value in errors.map({ $0 as Any }) + [credential, credential.accessToken] {
            for text in renderings(of: value) {
                #expect(!text.contains("sk-ant-oat01-TEST"), "\(text)")
                #expect(!text.contains("sk-ant-ort01-TEST"), "\(text)")
                #expect(!text.contains("0123456789"), "\(text)")
            }
        }
    }
}

// MARK: - Resolver

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func increment() {
        lock.withLock { reads += 1 }
    }

    var count: Int {
        lock.withLock { reads }
    }
}

private struct StubSource: CredentialSource {
    let label: String
    let result: Result<Data?, CredentialError>
    let counter = ReadCounter()

    init(_ label: String, json: String?) {
        self.label = label
        result = .success(json.map { Data($0.utf8) })
    }

    init(_ label: String, error: CredentialError) {
        self.label = label
        result = .failure(error)
    }

    func readCredentialData() throws(CredentialError) -> Data? {
        counter.increment()
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }
}

private func token(_ value: String) -> String {
    #"{"claudeAiOauth": {"accessToken": "\#(value)", "expiresAt": 1792605287037}}"#
}

@Suite struct CredentialResolverTests {
    @Test func resolverSkipsMcpOnlyThenUsesNext() throws {
        let mcpOnly = StubSource("plain", json: #"{"mcpOAuth": {"server": {"accessToken": "sk-ant-oat01-TEST-mcp"}}}"#)
        let hashed = StubSource("hashed", json: token("sk-ant-oat01-TEST-hashed"))
        let file = StubSource("file", json: token("sk-ant-oat01-TEST-file"))

        let credential = try CredentialResolver(sources: [mcpOnly, hashed, file]).resolve()

        #expect(credential.accessToken.withValue { $0 } == "sk-ant-oat01-TEST-hashed")
        #expect(mcpOnly.counter.count == 1)
        #expect(hashed.counter.count == 1)
        #expect(file.counter.count == 0)
    }

    @Test func resolverFallsThroughEveryKindOfFailure() throws {
        let sources: [any CredentialSource] = [
            StubSource("missing", json: nil),
            // A Keychain failure that is not a refusal is skipped like any other.
            StubSource("keychain error", error: .keychain(errSecNoSuchKeychain)),
            StubSource("insecure", error: .insecureFile),
            StubSource("malformed", json: "{"),
            StubSource("empty token", json: token("")),
            StubSource("usable", json: token("sk-ant-oat01-TEST-last")),
        ]
        let credential = try CredentialResolver(sources: sources).resolve()
        #expect(credential.accessToken.withValue { $0 } == "sk-ant-oat01-TEST-last")
    }

    @Test func resolverNotFound() {
        #expect(throws: CredentialError.notFound) { try CredentialResolver(sources: []).resolve() }

        let empty = CredentialResolver(sources: [StubSource("a", json: nil), StubSource("b", json: nil)])
        #expect(throws: CredentialError.notFound) { try empty.resolve() }
    }

    @Test func resolverReportsTheFirstFailureWhenNothingIsUsable() {
        let resolver = CredentialResolver(sources: [
            StubSource("missing", json: nil),
            StubSource("mcp only", json: #"{"mcpOAuth": {}}"#),
            StubSource("insecure", error: .insecureFile),
        ])
        #expect(throws: CredentialError.missingClaudeAiOauth) { try resolver.resolve() }

        let denied = CredentialResolver(sources: [
            StubSource("denied", error: .keychain(errSecAuthFailed)),
            StubSource("missing", json: nil),
        ])
        #expect(throws: CredentialError.keychain(errSecAuthFailed)) { try denied.resolve() }
    }

    @Test func keychainRefusalIsRecognized() {
        #expect(CredentialError.keychain(errSecUserCanceled).isKeychainAccessDenied)
        #expect(CredentialError.keychain(errSecAuthFailed).isKeychainAccessDenied)
        #expect(CredentialError.keychain(errSecInteractionNotAllowed).isKeychainAccessDenied)

        #expect(!CredentialError.keychain(errSecNoSuchKeychain).isKeychainAccessDenied)
        #expect(!CredentialError.keychain(errSecParam).isKeychainAccessDenied)
        for error: CredentialError in [.notFound, .malformed, .missingClaudeAiOauth, .emptyToken, .insecureFile] {
            #expect(!error.isKeychainAccessDenied)
        }
    }

    @Test func refusalStopsResolutionEvenWithAUsableFile() {
        // "Deny" means no: neither a second Keychain prompt nor a token from the credentials file may override it,
        // or the refusal would be swallowed and the prompt would come back on every poll.
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            let denied = StubSource("plain", error: .keychain(status))
            let hashed = StubSource("hashed", json: token("sk-ant-oat01-TEST-hashed"))
            let file = StubSource("file", json: token("sk-ant-oat01-TEST-file"))

            #expect(throws: CredentialError.keychain(status)) {
                try CredentialResolver(sources: [denied, hashed, file]).resolve()
            }
            #expect(denied.counter.count == 1)
            #expect(hashed.counter.count == 0)
            #expect(file.counter.count == 0)
        }
    }

    @Test func refusalWinsOverEarlierErrors() {
        // An earlier source that failed differently must not hide the refusal.
        let resolver = CredentialResolver(sources: [
            StubSource("mcp only", json: #"{"mcpOAuth": {}}"#),
            StubSource("hashed", error: .keychain(errSecAuthFailed)),
            StubSource("file", json: token("sk-ant-oat01-TEST-file")),
        ])
        #expect(throws: CredentialError.keychain(errSecAuthFailed)) { try resolver.resolve() }
    }

    @Test func resolverReReadsOnEveryCall() throws {
        let source = StubSource("only", json: token("sk-ant-oat01-TEST"))
        let resolver = CredentialResolver(sources: [source])
        for _ in 0..<3 {
            _ = try resolver.resolve()
        }
        #expect(source.counter.count == 3)
    }

    @Test func standardOrder() throws {
        let paths = ClaudePaths(homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true))
        let hashedService = try #require(paths.keychainServiceNames.last)
        #expect(hashedService.hasPrefix("Claude Code-credentials-"))

        let sources = CredentialResolver.standard(paths: paths).sources

        #expect(
            sources.map { $0.label } == [
                "Keychain: Claude Code-credentials",
                "Keychain: \(hashedService)",
                "File: /Users/test/.claude/.credentials.json",
            ]
        )
        #expect(sources.count == 3)
        #expect((sources[0] as? KeychainCredentialSource)?.service == "Claude Code-credentials")
        #expect((sources[1] as? KeychainCredentialSource)?.service == hashedService)
        #expect((sources[2] as? FileCredentialSource)?.fileURL == paths.credentialsFile)
    }

    /// The plain item belongs to the default config directory, so a custom `D` must never read it.
    @Test func standardOrderForCustomDirectoryOmitsThePlainItem() {
        let custom = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaRingCustomClaude-\(UUID().uuidString)", isDirectory: true)
        let paths = ClaudePaths(
            customConfigDirectory: custom,
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )
        let directory = custom.path
        #expect(!directory.hasSuffix("/") && paths.configDirectory.path == directory)
        let digest = SHA256.hash(data: Data(directory.utf8))
        let hash8 = String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))

        let labels = CredentialResolver.standard(paths: paths).sources.map { $0.label }

        #expect(
            labels == [
                "Keychain: Claude Code-credentials-\(hash8)",
                "File: \(directory)/.credentials.json",
            ]
        )
        #expect(!labels.contains("Keychain: Claude Code-credentials"))
    }
}

// MARK: - Keychain source

/// The Keychain itself is never touched in tests; only the query that would be sent is checked.
@Suite struct KeychainCredentialSourceTests {
    @Test func keychainQueryIsPinnedAndReadOnly() {
        let query = KeychainCredentialSource.query(service: "Claude Code-credentials")

        #expect(
            Set(query.keys) == [
                kSecClass as String,
                kSecAttrService as String,
                kSecMatchLimit as String,
                kSecReturnData as String,
            ]
        )
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "Claude Code-credentials")
        #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecReturnData as String] as? Bool == true)

        // Spelled out for auditors (the exact key set above already excludes them): no account filter, no Data
        // Protection keychain, no attribute or reference returns, and nothing that writes or changes an item.
        let absent: [CFString] = [
            kSecAttrAccount,
            kSecUseDataProtectionKeychain,
            kSecReturnAttributes,
            kSecReturnRef,
            kSecReturnPersistentRef,
            kSecValueData,
            kSecValueRef,
            kSecValuePersistentRef,
            kSecAttrAccessible,
            kSecAttrAccessControl,
            kSecAttrAccessGroup,
            kSecAttrSynchronizable,
            kSecAttrLabel,
            kSecAttrComment,
        ]
        for key in absent {
            #expect(query[key as String] == nil, "\(key)")
        }
    }

    @Test func keychainQueryUsesTheGivenService() {
        let hashed = "Claude Code-credentials-0123abcd"
        #expect(KeychainCredentialSource.query(service: hashed)[kSecAttrService as String] as? String == hashed)
        #expect(KeychainCredentialSource(service: hashed).service == hashed)
    }
}

// MARK: - File source

/// A fresh directory under the per-user temporary directory, removed by `remove()`.
private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaRingCredentialTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String, contents: Data, mode: Int) throws -> URL {
        let fileURL = url.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fileURL.path)
        return fileURL
    }
}

@Suite struct FileCredentialSourceTests {
    private let contents = Data(token("sk-ant-oat01-TEST-file").utf8)

    @Test func fileSourceRejectsGroupReadable() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let fileURL = try directory.file(".credentials.json", contents: contents, mode: 0o644)
        #expect(throws: CredentialError.insecureFile) {
            try FileCredentialSource(fileURL: fileURL).readCredentialData()
        }

        for mode in [0o640, 0o620, 0o610, 0o604, 0o602, 0o601, 0o666, 0o777] {
            let other = try directory.file("mode-\(String(mode, radix: 8)).json", contents: contents, mode: mode)
            #expect(throws: CredentialError.insecureFile, "mode \(String(mode, radix: 8))") {
                try FileCredentialSource(fileURL: other).readCredentialData()
            }
        }
    }

    @Test func fileSourceAcceptsOwnerOnly() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let fileURL = try directory.file(".credentials.json", contents: contents, mode: 0o600)
        let data = try FileCredentialSource(fileURL: fileURL).readCredentialData()
        #expect(data == contents)

        let readOnly = try directory.file("read-only.json", contents: contents, mode: 0o400)
        #expect(try FileCredentialSource(fileURL: readOnly).readCredentialData() == contents)

        let resolved = try CredentialResolver(sources: [FileCredentialSource(fileURL: fileURL)]).resolve()
        #expect(resolved.accessToken.withValue { $0 } == "sk-ant-oat01-TEST-file")
    }

    @Test func fileSourceRejectsSymlink() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        // The target itself would be accepted; only the symlink is refused.
        let target = try directory.file("target.json", contents: contents, mode: 0o600)
        let link = directory.url.appendingPathComponent(".credentials.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(try FileCredentialSource(fileURL: target).readCredentialData() == contents)
        #expect(throws: CredentialError.insecureFile) { try FileCredentialSource(fileURL: link).readCredentialData() }

        let dangling = directory.url.appendingPathComponent("dangling.json", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: directory.url.appendingPathComponent("nowhere.json")
        )
        #expect(throws: CredentialError.insecureFile) {
            try FileCredentialSource(fileURL: dangling).readCredentialData()
        }
    }

    @Test func fileSourceMissingFileIsNil() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let missing = directory.url.appendingPathComponent(".credentials.json", isDirectory: false)
        #expect(try FileCredentialSource(fileURL: missing).readCredentialData() == nil)

        let missingParent = directory.url.appendingPathComponent("no-such-dir/.credentials.json", isDirectory: false)
        #expect(try FileCredentialSource(fileURL: missingParent).readCredentialData() == nil)
    }

    @Test func fileSourceRejectsNonRegularFiles() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let subdirectory = directory.url.appendingPathComponent("dir.json", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: subdirectory.path)
        #expect(throws: CredentialError.insecureFile) {
            try FileCredentialSource(fileURL: subdirectory).readCredentialData()
        }

        // A FIFO must be refused without blocking in open(2) waiting for a writer.
        let fifo = directory.url.appendingPathComponent("fifo.json", isDirectory: false)
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: CredentialError.insecureFile) { try FileCredentialSource(fileURL: fifo).readCredentialData() }
    }

    @Test func fileSourceRejectsOversizedFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        let limit = 1_048_576
        let atLimit = try directory.file("at-limit.json", contents: Data(count: limit), mode: 0o600)
        #expect(try FileCredentialSource(fileURL: atLimit).readCredentialData()?.count == limit)

        let overLimit = try directory.file("over-limit.json", contents: Data(count: limit + 1), mode: 0o600)
        #expect(throws: CredentialError.insecureFile) {
            try FileCredentialSource(fileURL: overLimit).readCredentialData()
        }
    }

    /// `open(2)` failures: permission problems are security refusals, anything else is an unreadable source.
    @Test func fileSourceMapsOpenFailures() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }

        // EACCES: a file the owner cannot read.
        let unreadable = try directory.file("unreadable.json", contents: contents, mode: 0o000)
        #expect(throws: CredentialError.insecureFile) {
            try FileCredentialSource(fileURL: unreadable).readCredentialData()
        }

        // ENOTDIR: a path under a regular file.
        let regular = try directory.file("not-a-directory", contents: contents, mode: 0o600)
        let underFile = regular.appendingPathComponent(".credentials.json", isDirectory: false)
        #expect(throws: CredentialError.malformed) {
            try FileCredentialSource(fileURL: underFile).readCredentialData()
        }
    }

    @Test func labelsCarryNoSecrets() {
        let file = FileCredentialSource(fileURL: URL(fileURLWithPath: "/Users/test/.claude/.credentials.json"))
        #expect(file.label == "File: /Users/test/.claude/.credentials.json")
        let keychain = KeychainCredentialSource(service: "Claude Code-credentials")
        #expect(keychain.label == "Keychain: Claude Code-credentials")
        #expect(keychain.service == "Claude Code-credentials")
    }
}
