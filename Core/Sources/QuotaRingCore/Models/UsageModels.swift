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
    /// `"<kind>"` or `"<kind>:<scopeName>"`, for example `session` or `weekly_scoped:Opus`.
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
