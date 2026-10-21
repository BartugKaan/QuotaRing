import Foundation

/// Finds Claude Code's OAuth access token by trying credential sources in order.
///
/// The resolver keeps no state: every ``resolve()`` re-reads the sources, and nothing is cached, written or refreshed.
/// Raw credential data is dropped as soon as it has been parsed.
public struct CredentialResolver: Sendable {
    public let sources: [any CredentialSource]

    public init(sources: [any CredentialSource]) {
        self.sources = sources
    }

    /// Sources in order: a ``KeychainCredentialSource`` for each service in `paths.keychainServiceNames`, in order,
    /// then a ``FileCredentialSource`` for `paths.credentialsFile`.
    public static func standard(paths: ClaudePaths) -> CredentialResolver {
        let keychain: [any CredentialSource] = paths.keychainServiceNames.map { KeychainCredentialSource(service: $0) }
        return CredentialResolver(sources: keychain + [FileCredentialSource(fileURL: paths.credentialsFile)])
    }

    /// Returns the credential from the first source whose data parses with a non-empty access token.
    ///
    /// A source that is missing, fails to read or holds unusable data is skipped. If no source succeeds, throws the
    /// first error encountered, or ``CredentialError/notFound`` when no source had any data.
    public func resolve() throws(CredentialError) -> OAuthCredential {
        var firstError: CredentialError?
        for source in sources {
            do throws(CredentialError) {
                guard let data = try source.readCredentialData() else { continue }
                return try OAuthCredential.parse(data)
            } catch {
                firstError = firstError ?? error
            }
        }
        throw firstError ?? .notFound
    }
}
