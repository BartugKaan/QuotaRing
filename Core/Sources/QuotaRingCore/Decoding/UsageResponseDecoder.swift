import Foundation

/// Why a usage response could not be turned into a ``UsageReport``.
public enum UsageDecodingError: Error, Equatable {
    /// The payload is not a JSON object.
    case notAnObject
    /// The payload is an object but contains neither usable `limits[]` entries nor usable legacy keys.
    case noUsableLimits
}

/// Tolerant decoder for the (undocumented, changeable) `/api/oauth/usage` response.
///
/// It works on `JSONSerialization` output rather than `Codable` so that one malformed entry never discards the whole
/// report: unusable `limits[]` entries are skipped, unknown keys are ignored and unknown limit kinds are kept as
/// ``LimitKind/other(_:)``. When `limits[]` yields no usable entry the legacy top-level keys are used instead.
public enum UsageResponseDecoder {
    /// At most this many usable `limits[]` entries are kept, in response order. Real responses have a handful; the cap
    /// keeps a hostile or broken response from making the popover build an unbounded number of rows.
    static let maxLimits = 32

    /// At most this many breakdown rows are kept, after de-duplication by `key`. Real responses have four.
    static let maxBreakdownRows = 16

    /// - Throws: ``UsageDecodingError/notAnObject`` for invalid JSON or a non-object root, and
    ///   ``UsageDecodingError/noUsableLimits`` when nothing displayable was found.
    public static func decode(_ data: Data) throws -> UsageReport {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageDecodingError.notAnObject
        }
        return try decode(object: object)
    }

    /// Decodes an already-parsed JSON value, for example the `utilization` object from Claude Code's cache.
    public static func decode(object: Any) throws -> UsageReport {
        guard let root = JSONValue.object(object) else {
            throw UsageDecodingError.notAnObject
        }

        var limits = Array((root["limits"] as? [Any] ?? []).lazy.compactMap(decodeLimit).prefix(maxLimits))
        if limits.isEmpty {
            limits = decodeLegacyLimits(root)
        }
        guard !limits.isEmpty else {
            throw UsageDecodingError.noUsableLimits
        }

        return UsageReport(
            limits: makeIDsUnique(limits),
            extraUsage: decodeExtraUsage(root["extra_usage"]),
            weeklyBreakdown: decodeWeeklyBreakdown(root["seven_day_breakdown"])
        )
    }

    /// Ids must be unique within a report. When a computed id repeats, later occurrences get `#2`, `#3`, … in
    /// encounter order (skipping any suffixed id that is already taken).
    private static func makeIDsUnique(_ limits: [UsageLimit]) -> [UsageLimit] {
        var usedIDs = Set<String>()
        var nextSuffix: [String: Int] = [:]
        return limits.map { limit in
            var limit = limit
            let baseID = limit.id
            if usedIDs.contains(baseID) {
                var suffix = nextSuffix[baseID, default: 2]
                while usedIDs.contains("\(baseID)#\(suffix)") { suffix += 1 }
                nextSuffix[baseID] = suffix + 1
                limit.id = "\(baseID)#\(suffix)"
            }
            usedIDs.insert(limit.id)
            return limit
        }
    }

    // MARK: limits[]

    private static func decodeLimit(_ value: Any) -> UsageLimit? {
        guard
            let entry = JSONValue.object(value),
            let rawKind = JSONValue.nonEmptyString(entry["kind"]),
            let percent = JSONValue.double(entry["percent"])
        else { return nil }

        return UsageLimit(
            kind: LimitKind(rawValue: rawKind),
            group: JSONValue.nonEmptyString(entry["group"]),
            percentUsed: clampPercent(percent),
            resetsAt: FlexibleDate.parse(entry["resets_at"]),
            scopeName: scopeName(from: entry["scope"]),
            severity: JSONValue.nonEmptyString(entry["severity"]),
            isActive: JSONValue.bool(entry["is_active"]) ?? false
        )
    }

    /// `scope` is `null` or `{model: {id, display_name}, surface}`; prefer the model's display name.
    private static func scopeName(from scope: Any?) -> String? {
        guard let scope = JSONValue.object(scope) else { return nil }
        if let model = JSONValue.object(scope["model"]) {
            if let name = JSONValue.nonEmptyString(model["display_name"]) { return name }
            if let id = JSONValue.nonEmptyString(model["id"]) { return id }
        }
        return JSONValue.nonEmptyString(scope["surface"])
    }

    // MARK: legacy keys

    private static func decodeLegacyLimits(_ root: [String: Any]) -> [UsageLimit] {
        let legacyKeys: [(key: String, kind: LimitKind, scopeName: String?)] = [
            ("five_hour", .session, nil),
            ("seven_day", .weeklyAll, nil),
            ("seven_day_opus", .weeklyScoped, "Opus"),
            ("seven_day_sonnet", .weeklyScoped, "Sonnet"),
        ]
        return legacyKeys.compactMap { legacy in
            guard
                let entry = JSONValue.object(root[legacy.key]),
                let utilization = JSONValue.double(entry["utilization"])
            else { return nil }
            return UsageLimit(
                kind: legacy.kind,
                percentUsed: clampPercent(utilization),
                resetsAt: FlexibleDate.parse(entry["resets_at"]),
                scopeName: legacy.scopeName
            )
        }
    }

    // MARK: extra usage and breakdown

    /// A `decimal_places` outside ``ExtraUsage/supportedDecimalPlaces`` and a `currency` that is not three uppercase
    /// ASCII letters (an ISO 4217 code) are dropped, so the defaults apply instead.
    private static func decodeExtraUsage(_ value: Any?) -> ExtraUsage? {
        guard let extra = JSONValue.object(value) else { return nil }
        return ExtraUsage(
            isEnabled: JSONValue.bool(extra["is_enabled"]) ?? false,
            monthlyLimitMinor: JSONValue.double(extra["monthly_limit"]),
            usedCreditsMinor: JSONValue.double(extra["used_credits"]),
            percentUsed: JSONValue.double(extra["utilization"]).map(clampPercent),
            currency: JSONValue.nonEmptyString(extra["currency"]).flatMap(currencyCode),
            decimalPlaces: JSONValue.int(extra["decimal_places"]).flatMap { places in
                ExtraUsage.supportedDecimalPlaces.contains(places) ? places : nil
            }
        )
    }

    /// The code if it matches `^[A-Z]{3}$`, else `nil`.
    private static func currencyCode(_ string: String) -> String? {
        let bytes = string.utf8
        guard bytes.count == 3, bytes.allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }) else {
            return nil
        }
        return string
    }

    /// Returns `nil` unless at least one row is usable. Rows are de-duplicated by `key` (the first one wins, so the
    /// popover never sees two rows with the same id) and capped at ``maxBreakdownRows``.
    private static func decodeWeeklyBreakdown(_ value: Any?) -> WeeklyBreakdown? {
        guard let breakdown = JSONValue.object(value) else { return nil }
        var seenKeys = Set<String>()
        var rows: [BreakdownRow] = []
        for row in (breakdown["rows"] as? [Any] ?? []).lazy.compactMap(decodeBreakdownRow) {
            guard rows.count < maxBreakdownRows else { break }
            if seenKeys.insert(row.key).inserted {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { return nil }
        return WeeklyBreakdown(
            asOf: FlexibleDate.parse(breakdown["as_of"]),
            windowStartedAt: FlexibleDate.parse(breakdown["window_started_at"]),
            rows: rows
        )
    }

    private static func decodeBreakdownRow(_ value: Any) -> BreakdownRow? {
        guard
            let row = JSONValue.object(value),
            let key = JSONValue.nonEmptyString(row["key"]),
            let percent = JSONValue.double(row["percent"])
        else { return nil }
        return BreakdownRow(
            key: key,
            displayName: JSONValue.nonEmptyString(row["display_name"]) ?? key,
            percent: clampPercent(percent)
        )
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

/// Strict, forgiving-by-omission accessors for `JSONSerialization` output. Each returns `nil` for a missing key,
/// `NSNull` or a value of the wrong type; in particular booleans are never mistaken for numbers.
enum JSONValue {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    /// A finite number. `NSNumber` bridges booleans, so those are excluded explicitly.
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    /// A number with no fractional part that fits in `Int`.
    static func int(_ value: Any?) -> Int? {
        guard let result = double(value), result == result.rounded(), abs(result) < 1e15 else { return nil }
        return Int(result)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
