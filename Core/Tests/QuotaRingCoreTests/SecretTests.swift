import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct SecretTests {
    private let raw = "sk-ant-oat01-DO-NOT-LEAK-0123456789"

    @Test func secretNeverPrints() {
        let secret = Secret(raw)

        var dumped = ""
        dump(secret, to: &dumped)
        var printed = ""
        print(secret, to: &printed)
        var debugPrinted = ""
        debugPrint(secret, to: &debugPrinted)

        let outputs = [
            "\(secret)",
            String(describing: secret),
            String(reflecting: secret),
            secret.description,
            secret.debugDescription,
            dumped,
            printed,
            debugPrinted,
            "\(Mirror(reflecting: secret).children.map { "\($0.label ?? "")=\($0.value)" })",
        ]
        for output in outputs {
            #expect(!output.contains(raw))
            #expect(!output.contains("DO-NOT-LEAK"))
        }
        #expect(secret.description == "<redacted>")
        #expect(secret.debugDescription == "<redacted>")
        #expect(Mirror(reflecting: secret).children.isEmpty)
    }

    @Test func withValueExposesValueOnlyInsideTheClosure() throws {
        let secret = Secret(raw)
        #expect(secret.withValue { $0 } == raw)
        #expect(secret.withValue { $0.count } == raw.count)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try secret.withValue { _ in throw Boom() }
        }
    }

    @Test func isEmptyReflectsTheValue() {
        #expect(Secret("").isEmpty)
        #expect(!Secret(raw).isEmpty)
    }

    @Test func credentialContainingSecretNeverPrints() {
        let credential = OAuthCredential(
            accessToken: Secret(raw),
            expiresAt: Date(timeIntervalSince1970: 1_792_605_287.037),
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_5x"
        )
        var dumped = ""
        dump(credential, to: &dumped)
        let outputs = ["\(credential)", String(describing: credential), String(reflecting: credential), dumped]
        for output in outputs {
            #expect(!output.contains(raw))
        }
    }
}

@Suite struct OAuthCredentialTests {
    private let now = Date(timeIntervalSince1970: 1_792_623_000)

    private func credential(expiresAt: Date?) -> OAuthCredential {
        OAuthCredential(accessToken: Secret("token"), expiresAt: expiresAt, subscriptionType: nil, rateLimitTier: nil)
    }

    @Test func expiryUsesSkew() {
        #expect(!credential(expiresAt: nil).isExpired(now: now))
        #expect(credential(expiresAt: now.addingTimeInterval(-3600)).isExpired(now: now))
        #expect(credential(expiresAt: now).isExpired(now: now))
        // Boundary: expired when expiresAt <= now + skew (default 60 s).
        #expect(credential(expiresAt: now.addingTimeInterval(60)).isExpired(now: now))
        #expect(!credential(expiresAt: now.addingTimeInterval(61)).isExpired(now: now))
        #expect(!credential(expiresAt: now.addingTimeInterval(1)).isExpired(now: now, skew: 0))
        #expect(credential(expiresAt: now).isExpired(now: now, skew: 0))
        #expect(credential(expiresAt: now.addingTimeInterval(299)).isExpired(now: now, skew: 300))
    }
}
