import Foundation

/// A Claude Code OAuth access token with its metadata. The token is held in a ``Secret``.
public struct OAuthCredential: Sendable {
    public var accessToken: Secret
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(
        accessToken: Secret,
        expiresAt: Date? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    /// Whether the token is expired, or will be within `skew` seconds. A credential without an expiry never expires.
    public func isExpired(now: Date, skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(skew)
    }
}
