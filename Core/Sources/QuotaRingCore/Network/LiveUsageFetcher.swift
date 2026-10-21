import Foundation

/// Result of one attempt to fetch live usage.
public enum LiveFetchResult: Sendable, Equatable {
    case snapshot(UsageSnapshot)
    /// The stored token has expired (or is about to); no request was made.
    case skippedExpired
    /// No usable credential could be obtained; no request was made.
    case skippedNoCredential
    case failed(UsageAPIError)
}

/// Combines a credential source with ``UsageAPIClient``: it never contacts the endpoint with a missing or expired
/// token, and it reports every outcome as a value.
public struct LiveUsageFetcher: Sendable {
    private let client: UsageAPIClient
    private let credentials: @Sendable () throws -> OAuthCredential
    private let now: @Sendable () -> Date

    /// - Parameter credentials: Supplies the current credential. Any error it throws means "no credential".
    public init(
        client: UsageAPIClient,
        credentials: @escaping @Sendable () throws -> OAuthCredential,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.credentials = credentials
        self.now = now
    }

    public func fetch() async -> LiveFetchResult {
        let credential: OAuthCredential
        do {
            credential = try credentials()
        } catch {
            return .skippedNoCredential
        }

        if credential.isExpired(now: now()) {
            return .skippedExpired
        }

        do throws(UsageAPIError) {
            return .snapshot(try await client.fetch(token: credential.accessToken))
        } catch {
            return .failed(error)
        }
    }
}
