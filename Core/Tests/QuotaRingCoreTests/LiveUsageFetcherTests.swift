import Foundation
import Testing

@testable import QuotaRingCore

private let now = Date(timeIntervalSince1970: 1_792_566_000)  // 2026-10-21T07:00:00Z
private let minimalBody = Data(#"{"five_hour":{"utilization":4.0,"resets_at":"2026-10-21T22:50:00+00:00"}}"#.utf8)

private func makeFetcher(
    transport: RecordingTransport,
    credentials: @escaping @Sendable () throws -> OAuthCredential
) -> LiveUsageFetcher {
    LiveUsageFetcher(
        client: UsageAPIClient(transport: transport, userAgent: "QuotaRing/0.1.0 (test)", now: { now }),
        credentials: credentials,
        now: { now }
    )
}

private struct CredentialFailure: Error {}

@Suite struct LiveUsageFetcherTests {
    @Test func expiredSkipsNetwork() async {
        let transport = RecordingTransport(status: 200, body: minimalBody)
        let fetcher = makeFetcher(transport: transport) {
            OAuthCredential(accessToken: Secret("sk-ant-oat01-TEST"), expiresAt: now.addingTimeInterval(-10))
        }

        let result = await fetcher.fetch()

        #expect(result == .skippedExpired)
        #expect(transport.requests.isEmpty)
    }

    @Test func nearlyExpiredTokenIsTreatedAsExpired() async {
        let transport = RecordingTransport(status: 200, body: minimalBody)
        let fetcher = makeFetcher(transport: transport) {
            OAuthCredential(accessToken: Secret("sk-ant-oat01-TEST"), expiresAt: now.addingTimeInterval(30))
        }

        #expect(await fetcher.fetch() == .skippedExpired)
        #expect(transport.requests.isEmpty)
    }

    @Test func credentialErrorSkips() async {
        let transport = RecordingTransport(status: 200, body: minimalBody)
        let fetcher = makeFetcher(transport: transport) { throw CredentialFailure() }

        #expect(await fetcher.fetch() == .skippedNoCredential)
        #expect(transport.requests.isEmpty)
    }

    @Test func validCredentialFetchesSnapshot() async throws {
        let transport = RecordingTransport(status: 200, body: minimalBody)
        let fetcher = makeFetcher(transport: transport) {
            OAuthCredential(accessToken: Secret("sk-ant-oat01-TEST"), expiresAt: now.addingTimeInterval(3600))
        }

        let result = await fetcher.fetch()

        guard case .snapshot(let snapshot) = result else {
            Issue.record("expected a snapshot, got \(result)")
            return
        }
        #expect(snapshot.source == .live)
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.report.session?.percentUsed == 4)

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-TEST")
    }

    @Test func credentialWithoutExpiryIsUsed() async {
        let transport = RecordingTransport(status: 200, body: minimalBody)
        let fetcher = makeFetcher(transport: transport) {
            OAuthCredential(accessToken: Secret("sk-ant-oat01-TEST"))
        }

        guard case .snapshot = await fetcher.fetch() else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(transport.requests.count == 1)
    }

    @Test func clientErrorsSurfaceAsFailed() async {
        let unauthorized = RecordingTransport(status: 401)
        let fetcher = makeFetcher(transport: unauthorized) {
            OAuthCredential(accessToken: Secret("sk-ant-oat01-TEST"))
        }
        #expect(await fetcher.fetch() == .failed(.unauthorized))

        let limited = RecordingTransport(status: 429, headers: ["Retry-After": "90"])
        let limitedFetcher = makeFetcher(transport: limited) {
            OAuthCredential(accessToken: Secret("sk-ant-oat01-TEST"))
        }
        #expect(await limitedFetcher.fetch() == .failed(.rateLimited(retryAfter: 90)))
    }
}
