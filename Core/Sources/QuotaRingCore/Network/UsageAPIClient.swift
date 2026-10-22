import Foundation

/// Constants of the (undocumented) OAuth usage endpoint. `api.anthropic.com` is the only host QuotaRing talks to.
public enum UsageAPI {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    /// The `User-Agent` QuotaRing identifies itself with.
    public static func userAgent(version: String) -> String {
        "QuotaRing/\(version) (+https://github.com/BartugKaan/QuotaRing)"
    }
}

/// Why a live fetch failed. Deliberately carries no underlying error, so nothing in it can contain a token.
public enum UsageAPIError: Error, Equatable, Sendable {
    /// HTTP 401 or 403: the token is expired, revoked or lacks the scope.
    case unauthorized
    /// HTTP 429, with the server's `Retry-After` hint in seconds when it sent a usable one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Any other non-success status, including a refused redirect (3xx).
    case server(status: Int)
    /// The request never produced a response (offline, timeout, TLS failure, ...).
    case network
    /// A success response whose body held no usable limits, or a response whose body was over the transport's size
    /// limit (whatever its status).
    case decoding
}

/// Fetches the current usage report from ``UsageAPI/endpoint``.
public struct UsageAPIClient: Sendable {
    private let transport: any HTTPTransport
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport,
        userAgent: String,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.userAgent = userAgent
        self.now = now
    }

    /// - Parameter token: The OAuth access token. It is placed in the `Authorization` header only and never stored.
    public func fetch(token: Secret) async throws(UsageAPIError) -> UsageSnapshot {
        let request = makeRequest(token: token)

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch HTTPTransportError.responseTooLarge {
            throw .decoding
        } catch {
            throw .network
        }

        let received = now()
        switch response.statusCode {
        case 200..<300:
            do {
                let report = try UsageResponseDecoder.decode(data)
                return UsageSnapshot(report: report, fetchedAt: received, source: .live)
            } catch {
                throw .decoding
            }
        case 401, 403:
            throw .unauthorized
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After")
            throw .rateLimited(retryAfter: RetryAfter.parse(header, now: received))
        default:
            throw .server(status: response.statusCode)
        }
    }

    private func makeRequest(token: Secret) -> URLRequest {
        var request = URLRequest(url: UsageAPI.endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue(token.withValue { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
        request.setValue(UsageAPI.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }
}
