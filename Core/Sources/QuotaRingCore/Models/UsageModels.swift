import Foundation

/// The kind of a usage limit reported by the usage endpoint.
///
/// Known kinds map to dedicated cases; anything the endpoint may add later is preserved as ``other(_:)`` so it can
/// still be displayed generically. The `Codable` form is the single raw string (`"session"`, `"weekly_all"`,
/// `"weekly_scoped"`, or the unknown string itself).
public enum LimitKind: Hashable, Sendable, Codable {
    case session
    case weeklyAll
    case weeklyScoped
    case other(String)

    /// Creates a kind from the wire string used by the usage endpoint.
    public init(rawValue: String) {
        switch rawValue {
        case "session": self = .session
        case "weekly_all": self = .weeklyAll
        case "weekly_scoped": self = .weeklyScoped
        default: self = .other(rawValue)
        }
    }

    /// The wire string for this kind.
    public var rawValue: String {
        switch self {
        case .session: "session"
        case .weeklyAll: "weekly_all"
        case .weeklyScoped: "weekly_scoped"
        case .other(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One usage limit (a rolling window with a percentage used and a reset time).
public struct UsageLimit: Hashable, Sendable, Codable, Identifiable {
    /// `"<kind>"` or `"<kind>:<scopeName>"`, for example `session` or `weekly_scoped:Opus`. The decoder appends
    /// `#2`, `#3`, … when a report would otherwise repeat an id.
    public var id: String
    public var kind: LimitKind
    public var group: String?
    /// Percent of the limit already used, `0...100`.
    public var percentUsed: Double
    public var resetsAt: Date?
    /// Display name of the model or surface a scoped limit applies to.
    public var scopeName: String?
    public var severity: String?
    public var isActive: Bool

    /// Percent of the limit still available, `0...100`.
    public var percentRemaining: Double {
        min(100, max(0, 100 - percentUsed))
    }

    /// - Parameter id: Pass `nil` (the default) to derive the identifier from `kind` and `scopeName`.
    public init(
        id: String? = nil,
        kind: LimitKind,
        group: String? = nil,
        percentUsed: Double,
        resetsAt: Date? = nil,
        scopeName: String? = nil,
        severity: String? = nil,
        isActive: Bool = false
    ) {
        self.id = id ?? Self.makeID(kind: kind, scopeName: scopeName)
        self.kind = kind
        self.group = group
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.scopeName = scopeName
        self.severity = severity
        self.isActive = isActive
    }

    /// The canonical identifier for a kind and optional scope name.
    public static func makeID(kind: LimitKind, scopeName: String?) -> String {
        guard let scopeName else { return kind.rawValue }
        return kind.rawValue + ":" + scopeName
    }
}

/// Pay-as-you-go ("extra usage") settings and consumption. Money values are in minor units (for example cents).
public struct ExtraUsage: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    public var monthlyLimitMinor: Double?
    public var usedCreditsMinor: Double?
    public var percentUsed: Double?
    public var currency: String?
    public var decimalPlaces: Int?

    /// The `decimal_places` values QuotaRing accepts. Real currencies use 0 to 4; a larger value would make the money
    /// formatter allocate and format that many digits, which can freeze or crash the app, so the decoder drops any
    /// value outside this range and the popover clamps to it again.
    public static let supportedDecimalPlaces: ClosedRange<Int> = 0...6

    public init(
        isEnabled: Bool,
        monthlyLimitMinor: Double? = nil,
        usedCreditsMinor: Double? = nil,
        percentUsed: Double? = nil,
        currency: String? = nil,
        decimalPlaces: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.monthlyLimitMinor = monthlyLimitMinor
        self.usedCreditsMinor = usedCreditsMinor
        self.percentUsed = percentUsed
        self.currency = currency
        self.decimalPlaces = decimalPlaces
    }

    /// The share of the monthly limit spent, `0...1`: the reported percentage, else the amount spent divided by the
    /// limit; `nil` when neither is known.
    public var fractionUsed: Double? {
        if let percentUsed, !percentUsed.isNaN {
            return min(1, max(0, percentUsed / 100))
        }
        guard let usedCreditsMinor, let monthlyLimitMinor, monthlyLimitMinor > 0 else { return nil }
        return min(1, max(0, usedCreditsMinor / monthlyLimitMinor))
    }

    /// Whether there is anything to show: extra usage is on and either the share spent or the amount is known. (A saved
    /// snapshot keeps no money amounts, so it may only have the share.)
    public var hasDisplayableUsage: Bool {
        isEnabled && (fractionUsed != nil || usedCreditsMinor != nil)
    }
}

/// One row of the weekly breakdown: a share of the week's usage attributed to a surface such as Claude Code.
public struct BreakdownRow: Hashable, Sendable, Codable, Identifiable {
    public var key: String
    public var displayName: String
    /// Share in percent, `0...100`.
    public var percent: Double

    public var id: String { key }

    public init(key: String, displayName: String, percent: Double) {
        self.key = key
        self.displayName = displayName
        self.percent = percent
    }
}

/// How the current weekly window's usage splits across surfaces.
public struct WeeklyBreakdown: Hashable, Sendable, Codable {
    public var asOf: Date?
    public var windowStartedAt: Date?
    public var rows: [BreakdownRow]

    public init(asOf: Date? = nil, windowStartedAt: Date? = nil, rows: [BreakdownRow]) {
        self.asOf = asOf
        self.windowStartedAt = windowStartedAt
        self.rows = rows
    }
}

/// Everything decoded from one usage response.
public struct UsageReport: Hashable, Sendable, Codable {
    public var limits: [UsageLimit]
    public var extraUsage: ExtraUsage?
    public var weeklyBreakdown: WeeklyBreakdown?

    /// The first session limit, if the response had one.
    public var session: UsageLimit? {
        limits.first { $0.kind == .session }
    }

    /// Limits of kind ``LimitKind/weeklyAll`` and ``LimitKind/weeklyScoped``, in response order.
    public var weeklyLimits: [UsageLimit] {
        limits.filter { $0.kind == .weeklyAll || $0.kind == .weeklyScoped }
    }

    /// Limits of kinds QuotaRing has no dedicated place for (``LimitKind/other(_:)``), in response order. They are shown
    /// generically, with ``UsageLimit/genericTitle``.
    public var otherLimits: [UsageLimit] {
        limits.filter {
            if case .other = $0.kind { return true }
            return false
        }
    }

    public init(limits: [UsageLimit], extraUsage: ExtraUsage? = nil, weeklyBreakdown: WeeklyBreakdown? = nil) {
        self.limits = limits
        self.extraUsage = extraUsage
        self.weeklyBreakdown = weeklyBreakdown
    }
}

/// Where a snapshot came from.
public enum SnapshotSource: String, Sendable, Codable {
    case claudeCodeCache
    case live
    case demo
}

/// A usage report together with when and how it was obtained.
public struct UsageSnapshot: Hashable, Sendable, Codable {
    public var report: UsageReport
    public var fetchedAt: Date
    public var source: SnapshotSource

    public init(report: UsageReport, fetchedAt: Date, source: SnapshotSource) {
        self.report = report
        self.fetchedAt = fetchedAt
        self.source = source
    }
}
