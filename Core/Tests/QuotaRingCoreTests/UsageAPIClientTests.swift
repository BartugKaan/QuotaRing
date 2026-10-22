import Foundation
import Testing
import os

@testable import QuotaRingCore

// MARK: - Test doubles

/// A transport that records every request and answers with a canned result.
final class RecordingTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private let log = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Answers every request with `status`, `body` and `headers`.
    convenience init(status: Int, body: Data = Data(), headers: [String: String] = [:]) {
        self.init { request in
            (body, RecordingTransport.response(for: request, status: status, headers: headers))
        }
    }

    var requests: [URLRequest] {
        log.withLock { $0 }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        log.withLock { $0.append(request) }
        return try handler(request)
    }

    static func response(for request: URLRequest, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url ?? UsageAPI.endpoint,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private let testUserAgent = "QuotaRing/0.1.0 (+https://github.com/BartugKaan/QuotaRing)"
private let testToken = Secret("sk-ant-oat01-TEST")
private let fixedNow = Date(timeIntervalSince1970: 1_792_566_000)  // 2026-10-21T07:00:00Z

private func makeClient(_ transport: RecordingTransport, now: Date = fixedNow) -> UsageAPIClient {
    UsageAPIClient(transport: transport, userAgent: testUserAgent, now: { now })
}

private func fetchError(_ client: UsageAPIClient) async -> UsageAPIError? {
    do {
        _ = try await client.fetch(token: testToken)
        return nil
    } catch {
        return error
    }
}

private struct TransportFailure: Error {}

// MARK: - Client

@Suite struct UsageAPIClientTests {
    @Test func sendsExactHeaders() async throws {
        let transport = RecordingTransport(status: 200, body: try fixtureData("usage-live-2026-10-21"))
        _ = try await makeClient(transport).fetch(token: testToken)

        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.url == UsageAPI.endpoint)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(
            request.allHTTPHeaderFields == [
                "Authorization": "Bearer sk-ant-oat01-TEST",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
                "User-Agent": "QuotaRing/0.1.0 (+https://github.com/BartugKaan/QuotaRing)",
            ])
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.httpBody == nil)
    }

    @Test func endpointConstantsAreExact() {
        #expect(UsageAPI.endpoint.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(UsageAPI.endpoint.host == "api.anthropic.com")
        #expect(UsageAPI.betaHeader == "oauth-2025-04-20")
        #expect(UsageAPI.userAgent(version: "1.2.3") == "QuotaRing/1.2.3 (+https://github.com/BartugKaan/QuotaRing)")
    }

    @Test func decodes200() async throws {
        let transport = RecordingTransport(status: 200, body: try fixtureData("usage-live-2026-10-21"))
        let snapshot = try await makeClient(transport).fetch(token: testToken)

        #expect(snapshot.source == .live)
        #expect(snapshot.fetchedAt == fixedNow)
        #expect(snapshot.report.limits.count == 3)
        #expect(snapshot.report.session?.percentUsed == 4)
        #expect(snapshot.report.weeklyLimits.map(\.id) == ["weekly_all", "weekly_scoped:Fable"])
    }

    @Test(arguments: [401, 403])
    func mapsUnauthorized(status: Int) async throws {
        let transport = RecordingTransport(status: status, body: try fixtureData("usage-error-401"))
        #expect(await fetchError(makeClient(transport)) == .unauthorized)
    }

    @Test func maps429WithRetryAfterSeconds() async {
        let transport = RecordingTransport(status: 429, headers: ["Retry-After": "120"])
        #expect(await fetchError(makeClient(transport)) == .rateLimited(retryAfter: 120))
    }

    @Test func maps429WithHTTPDate() async {
        let transport = RecordingTransport(status: 429, headers: ["Retry-After": "Wed, 21 Oct 2026 07:02:00 GMT"])
        #expect(await fetchError(makeClient(transport)) == .rateLimited(retryAfter: 120))
    }

    @Test func maps429WithoutHeader() async {
        let transport = RecordingTransport(status: 429)
        #expect(await fetchError(makeClient(transport)) == .rateLimited(retryAfter: nil))
    }

    @Test func maps429WithGarbageHeader() async {
        let transport = RecordingTransport(status: 429, headers: ["Retry-After": "soon"])
        #expect(await fetchError(makeClient(transport)) == .rateLimited(retryAfter: nil))
    }

    @Test(arguments: [500, 502, 503, 529])
    func maps5xx(status: Int) async {
        let transport = RecordingTransport(status: status)
        #expect(await fetchError(makeClient(transport)) == .server(status: status))
    }

    @Test(arguments: [400, 404, 422])
    func maps4xxToServerStatus(status: Int) async {
        let transport = RecordingTransport(status: status)
        #expect(await fetchError(makeClient(transport)) == .server(status: status))
    }

    /// Redirects are refused by the transport, so the client sees the 3xx itself and must not treat it as success.
    @Test func mapsRedirectResponseToServerStatus() async {
        let transport = RecordingTransport(status: 302, headers: ["Location": "https://example.invalid/"])
        #expect(await fetchError(makeClient(transport)) == .server(status: 302))
        #expect(transport.requests.count == 1)
    }

    @Test func mapsTransportErrorToNetwork() async {
        let transport = RecordingTransport { _ in throw TransportFailure() }
        #expect(await fetchError(makeClient(transport)) == .network)
    }

    @Test func mapsURLErrorToNetwork() async {
        let transport = RecordingTransport { _ in throw URLError(.notConnectedToInternet) }
        #expect(await fetchError(makeClient(transport)) == .network)
    }

    @Test func badBodyIsDecoding() async {
        let notJSON = RecordingTransport(status: 200, body: Data("<html>oops</html>".utf8))
        #expect(await fetchError(makeClient(notJSON)) == .decoding)

        let noLimits = RecordingTransport(status: 200, body: Data("{}".utf8))
        #expect(await fetchError(makeClient(noLimits)) == .decoding)

        let empty = RecordingTransport(status: 200)
        #expect(await fetchError(makeClient(empty)) == .decoding)
    }

    @Test func errorsCarryNoPayloadThatCouldLeakTheToken() async {
        let transport = RecordingTransport { _ in throw URLError(.timedOut) }
        let error = await fetchError(makeClient(transport))
        #expect(error == .network)
        #expect(!String(describing: error).contains("sk-ant-oat01-TEST"))
    }
}

// MARK: - Retry-After

@Suite struct RetryAfterTests {
    @Test func parsesDeltaSeconds() {
        #expect(RetryAfter.parse("120", now: fixedNow) == 120)
        #expect(RetryAfter.parse("0", now: fixedNow) == 0)
        #expect(RetryAfter.parse("  30 ", now: fixedNow) == 30)
    }

    @Test func parsesIMFFixdateRelativeToNow() {
        #expect(RetryAfter.parse("Wed, 21 Oct 2026 07:02:00 GMT", now: fixedNow) == 120)
        #expect(RetryAfter.parse("Wed, 21 Oct 2026 08:00:00 GMT", now: fixedNow) == 3600)
    }

    @Test func clampsPastDatesToZero() {
        #expect(RetryAfter.parse("Wed, 21 Oct 2026 06:00:00 GMT", now: fixedNow) == 0)
    }

    @Test(arguments: [nil, "", "   ", "soon", "-5", "1.5", "12s", "2026-10-21T07:02:00Z", "99999999999999999999999"])
    func rejectsGarbage(header: String?) {
        #expect(RetryAfter.parse(header, now: fixedNow) == nil)
    }
}

// MARK: - URLSessionTransport

/// Answers the first request with a 302 to another host and records every URL it is asked to load.
final class RedirectingURLProtocol: URLProtocol {
    static let loadedURLs = OSAllocatedUnfairLock<[URL]>(initialState: [])
    static let redirectTarget = URL(string: "https://redirect-target.invalid/collect")!

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.loadedURLs.withLock { $0.append(url) }

        let target = Self.redirectTarget
        if url == target {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("followed".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let redirect = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
        // A custom protocol must deliver the redirect itself when the task delegate declines to follow it.
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct URLSessionTransportTests {
    @Test func configurationKeepsNoStateAndHasATimeout() {
        let configuration = URLSessionTransport.makeConfiguration()

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 30)
    }

    @Test func redirectDelegateDeclinesEveryRedirect() throws {
        let delegate = RedirectRefusingDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: UsageAPI.endpoint)
        let redirect = RecordingTransport.response(
            for: URLRequest(url: UsageAPI.endpoint),
            status: 302,
            headers: ["Location": "https://redirect-target.invalid/collect"]
        )
        let outcome = OSAllocatedUnfairLock<[URLRequest?]>(initialState: [])

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: RedirectingURLProtocol.redirectTarget)
        ) { followed in
            outcome.withLock { $0.append(followed) }
        }

        let results = outcome.withLock { $0 }
        #expect(results.count == 1)
        let followed = try #require(results.first)
        #expect(followed == nil)
    }

    @Test func redirectIsReturnedNotFollowed() async throws {
        RedirectingURLProtocol.loadedURLs.withLock { $0.removeAll() }
        let configuration = URLSessionTransport.makeConfiguration()
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let transport = URLSessionTransport(configuration: configuration)

        var request = URLRequest(url: UsageAPI.endpoint)
        request.setValue("Bearer sk-ant-oat01-TEST", forHTTPHeaderField: "Authorization")
        let (_, response) = try await transport.send(request)

        #expect(response.statusCode == 302)
        let loaded = RedirectingURLProtocol.loadedURLs.withLock { $0 }
        #expect(loaded == [UsageAPI.endpoint])
        #expect(!loaded.contains(RedirectingURLProtocol.redirectTarget))
    }
}
