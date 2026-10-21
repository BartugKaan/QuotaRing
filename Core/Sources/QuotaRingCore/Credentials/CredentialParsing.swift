import Foundation
import Security

/// Why no usable credential could be read.
///
/// The cases deliberately carry no token, file content, path or underlying decoder error, so an error can be shown or
/// logged by callers without leaking anything.
public enum CredentialError: Error, Equatable {
    /// No source had any credential data.
    case notFound
    /// The data is too large, not the expected JSON shape, or the token has invalid characters; or the source could
    /// not be read for a reason other than a security refusal (for example `EMFILE`, `ENFILE`, `ENOTDIR`, an I/O
    /// error, or a Keychain result that is not data).
    case malformed
    /// The JSON has no `claudeAiOauth` object (for example it holds only `mcpOAuth`).
    case missingClaudeAiOauth
    /// `claudeAiOauth.accessToken` is missing, `null` or empty.
    case emptyToken
    /// The credentials file was refused: it is a symlink (`ELOOP`), opening it was denied (`EACCES`, `EPERM`), or it is
    /// not a regular file owned by the current user with owner-only permissions and at most 1 MiB.
    case insecureFile
    /// The Keychain lookup failed with this status (other than `errSecItemNotFound`). See
    /// ``isKeychainAccessDenied`` for the statuses that mean the user (or a locked keychain) refused access.
    case keychain(OSStatus)

    /// Whether the Keychain refused access rather than failing: the user clicked "Deny" or cancelled the access prompt
    /// (`errSecUserCanceled`), entered no valid password (`errSecAuthFailed`), or the keychain is locked and no prompt
    /// could be shown (`errSecInteractionNotAllowed`). Asking again without the user's say-so would just show the same
    /// prompt again.
    public var isKeychainAccessDenied: Bool {
        guard case .keychain(let status) = self else { return false }
        return Self.accessDeniedStatuses.contains(status)
    }

    static let accessDeniedStatuses: Set<OSStatus> = [
        errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed,
    ]
}

extension OAuthCredential {
    /// Upper bound for credential data from any source. The real item is a few kilobytes.
    static let maxCredentialDataSize = 1_048_576

    /// Parses Claude Code's credential JSON.
    ///
    /// Only `claudeAiOauth.accessToken`, `expiresAt` (milliseconds since the Unix epoch), `subscriptionType` and
    /// `rateLimitTier` are read. This code never reads `refreshToken`, `mcpOAuth` or any other key. The token goes into
    /// a ``Secret`` as soon as it is decoded and must be non-empty, visible ASCII (it is sent in an HTTP header).
    public static func parse(_ data: Data) throws(CredentialError) -> OAuthCredential {
        guard data.count <= maxCredentialDataSize else { throw .malformed }

        let document: CredentialDocument
        do {
            document = try JSONDecoder().decode(CredentialDocument.self, from: data)
        } catch {
            // The decoder's error may quote the input, so it is dropped.
            throw .malformed
        }

        guard let oauth = document.claudeAiOauth else { throw .missingClaudeAiOauth }
        guard let accessToken = oauth.accessToken, !accessToken.isEmpty else { throw .emptyToken }
        guard accessToken.withValue(isVisibleASCII) else { throw .malformed }

        return OAuthCredential(
            accessToken: accessToken,
            expiresAt: oauth.expiresAt,
            subscriptionType: oauth.subscriptionType,
            rateLimitTier: oauth.rateLimitTier
        )
    }

    private static func isVisibleASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

/// The subset of the credential JSON that QuotaRing reads. Keys not declared here are never requested from the
/// decoder.
private struct CredentialDocument: Decodable {
    var claudeAiOauth: ClaudeAiOauth?

    struct ClaudeAiOauth: Decodable {
        var accessToken: Secret?
        var expiresAt: Date?
        var subscriptionType: String?
        var rateLimitTier: String?

        private enum CodingKeys: String, CodingKey {
            case accessToken, expiresAt, subscriptionType, rateLimitTier
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken).map(Secret.init)
            expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt).map {
                Date(timeIntervalSince1970: $0 / 1000)
            }
            // Display-only metadata: an unexpected type is ignored rather than rejecting the credential.
            subscriptionType = try? container.decodeIfPresent(String.self, forKey: .subscriptionType)
            rateLimitTier = try? container.decodeIfPresent(String.self, forKey: .rateLimitTier)
        }
    }
}
