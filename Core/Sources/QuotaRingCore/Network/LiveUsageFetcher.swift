import Foundation

/// Result of one attempt to fetch live usage.
public enum LiveFetchResult: Sendable, Equatable {
    case snapshot(UsageSnapshot)
    /// The stored token has expired (or is about to); no request was made.
    case skippedExpired
    /// No usable credential could be obtained, for the given reason; no request was made. A reason for which
    /// ``CredentialError/isKeychainAccessDenied`` is `true` means the user refused Keychain access.
    case skippedNoCredential(CredentialError)
    case failed(UsageAPIError)
}

/// Combines a credential source with ``UsageAPIClient``: it never contacts the endpoint with a missing or expired
/// token, and it reports every outcome as a value.
public struct LiveUsageFetcher: Sendable {
    private let client: UsageAPIClient
    private let credentials: @Sendable () throws(CredentialError) -> OAuthCredential
    private let now: @Sendable () -> Date

    /// - Parameter credentials: Supplies the current credential. The error it throws is reported as
    ///   ``LiveFetchResult/skippedNoCredential(_:)``.
    public init(
        client: UsageAPIClient,
        credentials: @escaping @Sendable () throws(CredentialError) -> OAuthCredential,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.credentials = credentials
        self.now = now
    }

    public func fetch() async -> LiveFetchResult {
        let credential: OAuthCredential
        do throws(CredentialError) {
            credential = try credentials()
        } catch {
            return .skippedNoCredential(error)
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
