import Foundation

/// Sends one HTTP request and returns the full response. Abstracted so the usage client can be tested without a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Why a transport refused a response it did receive.
public enum HTTPTransportError: Error, Equatable, Sendable {
    /// The body is larger than the transport accepts (``URLSessionTransport/maxBodyBytes``), whatever the status.
    case responseTooLarge
}

/// The production transport: an ephemeral `URLSession` that keeps no cookies, cache or credentials and refuses every
/// redirect, so a bearer token can never be forwarded to another host. A 3xx response is returned to the caller as is.
///
/// The body is streamed and capped at ``maxBodyBytes``: a response that declares a larger `Content-Length` is refused
/// before its body is read, and one that streams more than that is cancelled as soon as it passes the limit. A hostile
/// endpoint or proxy therefore cannot make QuotaRing buffer an unbounded body.
public struct URLSessionTransport: HTTPTransport {
    /// The largest response body accepted, 1 MiB. Real usage responses are a few kilobytes.
    public static let maxBodyBytes = 1 << 20

    private let session: URLSession

    public init() {
        self.init(configuration: Self.makeConfiguration())
    }

    init(configuration: URLSessionConfiguration) {
        self.session = URLSession(configuration: configuration)
    }

    /// - Throws: ``HTTPTransportError/responseTooLarge`` for a body over ``maxBodyBytes``, `URLError` otherwise.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectRefusingDelegate())
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        // `expectedContentLength` is -1 when the length is unknown (for example a chunked response); the read loop
        // below enforces the limit then. With a compressed body it is the compressed length, while the loop counts the
        // decompressed bytes, so a small body that inflates past the limit is caught there too.
        if http.expectedContentLength > Int64(Self.maxBodyBytes) {
            bytes.task.cancel()
            throw HTTPTransportError.responseTooLarge
        }

        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < Self.maxBodyBytes else {
                bytes.task.cancel()
                throw HTTPTransportError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, http)
    }

    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }
}

/// Task delegate that declines every redirect. Completing with `nil` makes URLSession deliver the 3xx response itself.
final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
