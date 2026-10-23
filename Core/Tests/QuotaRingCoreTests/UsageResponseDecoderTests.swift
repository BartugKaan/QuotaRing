import Foundation
import Testing

@testable import QuotaRingCore

private func fixtureData(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func decode(json: String) throws -> UsageReport {
    try UsageResponseDecoder.decode(Data(json.utf8))
}

private func seconds(_ date: Date?) -> Double {
    date?.timeIntervalSince1970 ?? .nan
}

@Suite struct UsageResponseDecoderTests {
    @Test func decodesLiveFixture() throws {
        let report = try UsageResponseDecoder.decode(fixtureData("usage-live-2026-10-21"))

        #expect(report.limits.count == 3)

        let session = try #require(report.session)
        #expect(session.id == "session")
        #expect(session.kind == .session)
        #expect(session.group == "session")
        #expect(session.percentUsed == 4)
        #expect(session.percentRemaining == 96)
        #expect(abs(seconds(session.resetsAt) - 1_792_623_000.192966) < 0.001)
        #expect(session.severity == "normal")
        #expect(session.scopeName == nil)
        #expect(session.isActive == false)

        let weeklyAll = try #require(report.limits.first { $0.kind == .weeklyAll })
        #expect(weeklyAll.id == "weekly_all")
        #expect(weeklyAll.group == "weekly")
        #expect(weeklyAll.percentUsed == 18)
        #expect(abs(seconds(weeklyAll.resetsAt) - 1_793_091_600.192984) < 0.001)
        #expect(weeklyAll.isActive == true)

        let scoped = try #require(report.limits.first { $0.kind == .weeklyScoped })
        #expect(scoped.id == "weekly_scoped:Fable")
        #expect(scoped.scopeName == "Fable")
        #expect(scoped.percentUsed == 0)
        #expect(abs(seconds(scoped.resetsAt) - 1_793_091_600) < 0.001)

        #expect(report.weeklyLimits.map(\.id) == ["weekly_all", "weekly_scoped:Fable"])

        let extra = try #require(report.extraUsage)
        #expect(extra.isEnabled == false)
        #expect(extra.monthlyLimitMinor == nil)
        #expect(extra.usedCreditsMinor == nil)
        #expect(extra.percentUsed == nil)
        #expect(extra.currency == nil)
        #expect(extra.decimalPlaces == nil)

        let breakdown = try #require(report.weeklyBreakdown)
        #expect(breakdown.rows.map(\.key) == ["claude_code", "chat", "cowork", "other"])
        #expect(breakdown.rows.map(\.percent) == [44, 1, 54, 1])
        #expect(breakdown.rows.map(\.displayName) == ["Claude Code", "Chats", "Cowork", "Other"])
        #expect(breakdown.rows.map(\.id) == ["claude_code", "chat", "cowork", "other"])
        #expect(abs(seconds(breakdown.asOf) - 1_792_605_311.211020) < 0.001)
        #expect(abs(seconds(breakdown.windowStartedAt) - 1_792_486_800.192984) < 0.001)
    }

    @Test func legacyOnlyFallsBack() throws {
        let report = try UsageResponseDecoder.decode(fixtureData("usage-legacy-only"))

        #expect(report.limits.map(\.id) == ["session", "weekly_all", "weekly_scoped:Opus"])

        let session = try #require(report.session)
        #expect(session.kind == .session)
        #expect(session.percentUsed == 37.5)
        // Epoch-number resets_at.
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_792_623_000))
        #expect(session.isActive == false)
        #expect(session.group == nil)
        #expect(session.severity == nil)

        let weekly = report.limits[1]
        #expect(weekly.kind == .weeklyAll)
        #expect(weekly.percentUsed == 18)
        #expect(abs(seconds(weekly.resetsAt) - 1_793_091_600.192984) < 0.001)
        #expect(weekly.isActive == false)
        #expect(weekly.group == nil)

        let opus = report.limits[2]
        #expect(opus.kind == .weeklyScoped)
        #expect(opus.scopeName == "Opus")
        #expect(opus.percentUsed == 7.25)
        #expect(opus.resetsAt == Date(timeIntervalSince1970: 1_793_091_600))

        let extra = try #require(report.extraUsage)
        #expect(extra.isEnabled)
        #expect(extra.monthlyLimitMinor == 5000)
        #expect(extra.usedCreditsMinor == 1250.5)
        #expect(extra.percentUsed == 25.01)
        #expect(extra.currency == "USD")
        #expect(extra.decimalPlaces == 2)
        #expect(report.weeklyBreakdown == nil)
    }

    @Test func legacySonnetAndNullKeys() throws {
        let report = try decode(
            json: """
                {"five_hour": null,
                 "seven_day": {"utilization": 10},
                 "seven_day_opus": null,
                 "seven_day_sonnet": {"utilization": 22, "resets_at": null}}
                """
        )
        #expect(report.limits.map(\.id) == ["weekly_all", "weekly_scoped:Sonnet"])
        #expect(report.session == nil)
        #expect(report.limits[0].resetsAt == nil)
        #expect(report.limits[1].resetsAt == nil)
    }

    @Test func malformedEntryIsSkipped() throws {
        let report = try UsageResponseDecoder.decode(fixtureData("usage-malformed-entry"))

        #expect(report.limits.map(\.id) == ["session", "monthly_pool", "weekly_scoped:Fable"])

        #expect(report.limits[0].isActive == true)

        let unknown = report.limits[1]
        #expect(unknown.kind == .other("monthly_pool"))
        #expect(unknown.group == "monthly")
        #expect(unknown.percentUsed == 62.5)
        #expect(unknown.severity == "warning")
        #expect(unknown.resetsAt == Date(timeIntervalSince1970: 1_793_491_200))

        // An unparsable resets_at does not discard the entry.
        let scoped = report.limits[2]
        #expect(scoped.scopeName == "Fable")
        #expect(scoped.resetsAt == nil)

        // extra_usage is only decoded when it is an object.
        #expect(report.extraUsage == nil)

        // Bad breakdown rows are skipped individually.
        let rows = try #require(report.weeklyBreakdown).rows
        #expect(rows.map(\.key) == ["claude_code", "other"])
        #expect(rows.map(\.percent) == [60, 40])
    }

    @Test func allNullThrows() throws {
        let data = try fixtureData("usage-all-null")
        #expect(throws: UsageDecodingError.noUsableLimits) {
            try UsageResponseDecoder.decode(data)
        }
        #expect(throws: UsageDecodingError.noUsableLimits) {
            try decode(json: "{}")
        }
        #expect(throws: UsageDecodingError.noUsableLimits) {
            try decode(json: #"{"limits": ["x", 3, null, {"kind": "session"}]}"#)
        }
    }

    @Test func nonObjectThrows() {
        #expect(throws: UsageDecodingError.notAnObject) { try decode(json: "[]") }
        #expect(throws: UsageDecodingError.notAnObject) { try decode(json: "42") }
        #expect(throws: UsageDecodingError.notAnObject) { try decode(json: "\"text\"") }
        #expect(throws: UsageDecodingError.notAnObject) { try decode(json: "null") }
        #expect(throws: UsageDecodingError.notAnObject) { try decode(json: "not json at all") }
        #expect(throws: UsageDecodingError.notAnObject) { try decode(json: "") }
        #expect(throws: UsageDecodingError.notAnObject) { try UsageResponseDecoder.decode(object: [1, 2, 3]) }
        #expect(throws: UsageDecodingError.notAnObject) { try UsageResponseDecoder.decode(object: NSNull()) }
    }

    @Test func percentIsClamped() throws {
        let fromLimits = try decode(
            json: """
                {"limits": [
                    {"kind": "session", "percent": 140},
                    {"kind": "weekly_all", "percent": -3}
                ]}
                """
        )
        #expect(fromLimits.limits.map(\.percentUsed) == [100, 0])
        #expect(fromLimits.limits.map(\.percentRemaining) == [0, 100])

        let fromLegacy = try decode(
            json: """
                {"five_hour": {"utilization": 250.5}, "seven_day": {"utilization": -0.5}}
                """
        )
        #expect(fromLegacy.limits.map(\.percentUsed) == [100, 0])
    }

    @Test func emptyLimitsArrayFallsBackToLegacyKeys() throws {
        let report = try decode(json: #"{"limits": [], "five_hour": {"utilization": 5}}"#)
        #expect(report.limits.map(\.id) == ["session"])
        #expect(report.session?.percentUsed == 5)
    }

    @Test func limitsArePreferredOverLegacyKeys() throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 4, "is_active": true}],
                 "five_hour": {"utilization": 99},
                 "seven_day": {"utilization": 98}}
                """
        )
        #expect(report.limits.count == 1)
        #expect(report.session?.percentUsed == 4)
    }

    @Test func booleansAreNotNumbers() throws {
        let report = try decode(
            json: """
                {"limits": [
                    {"kind": "session", "percent": true},
                    {"kind": "weekly_all", "percent": 7, "is_active": 1, "resets_at": true}
                ]}
                """
        )
        #expect(report.limits.map(\.id) == ["weekly_all"])
        #expect(report.limits[0].isActive == false)
        #expect(report.limits[0].resetsAt == nil)
    }

    @Test func scopeNameFallsBackToModelIdThenSurface() throws {
        let report = try decode(
            json: """
                {"limits": [
                    {"kind": "weekly_scoped", "percent": 1, "scope": {"model": {"id": "m-1", "display_name": ""}}},
                    {"kind": "weekly_scoped", "percent": 2, "scope": {"model": null, "surface": "cli"}},
                    {"kind": "weekly_scoped", "percent": 3, "scope": {"model": {"display_name": "Opus"}}},
                    {"kind": "weekly_scoped", "percent": 4, "scope": "not an object"}
                ]}
                """
        )
        #expect(report.limits.map(\.scopeName) == ["m-1", "cli", "Opus", nil])
        #expect(
            report.limits.map(\.id) == [
                "weekly_scoped:m-1", "weekly_scoped:cli", "weekly_scoped:Opus", "weekly_scoped",
            ]
        )
    }

    @Test func extraUsageDecodesNumbersLeniently() throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "extra_usage": {"is_enabled": true, "monthly_limit": 1000, "used_credits": 5e2,
                                 "utilization": 150, "currency": "EUR", "decimal_places": 2.0}}
                """
        )
        let extra = try #require(report.extraUsage)
        #expect(extra.isEnabled)
        #expect(extra.monthlyLimitMinor == 1000)
        #expect(extra.usedCreditsMinor == 500)
        #expect(extra.percentUsed == 100)
        #expect(extra.currency == "EUR")
        #expect(extra.decimalPlaces == 2)

        let sparse = try decode(json: #"{"limits": [{"kind": "session", "percent": 1}], "extra_usage": {}}"#)
        #expect(sparse.extraUsage == ExtraUsage(isEnabled: false))
    }

    @Test(arguments: ["999999999999999", "100000000", "7", "-1", "-999999999999999", "1.5"])
    func decimalPlacesOutsideTheSupportedRangeAreDropped(places: String) throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "extra_usage": {"is_enabled": true, "used_credits": 1, "currency": "USD", "decimal_places": \(places)}}
                """
        )
        let extra = try #require(report.extraUsage)
        #expect(extra.decimalPlaces == nil)
        // The rest of the entry is kept.
        #expect(extra.isEnabled)
        #expect(extra.usedCreditsMinor == 1)
        #expect(extra.currency == "USD")
    }

    @Test(arguments: [0, 3, 6])
    func decimalPlacesInsideTheSupportedRangeAreKept(places: Int) throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "extra_usage": {"is_enabled": true, "decimal_places": \(places)}}
                """
        )
        #expect(report.extraUsage?.decimalPlaces == places)
    }

    @Test(arguments: [
        #""usd""#, #""US""#, #""USDT""#, #""U$D""#, #""ÜSD""#, #"" USD""#, #""US\nD""#, "42", "null", #""""#,
    ])
    func currencyThatIsNotAnISOCodeIsDropped(currency: String) throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "extra_usage": {"is_enabled": true, "used_credits": 1, "currency": \(currency), "decimal_places": 2}}
                """
        )
        let extra = try #require(report.extraUsage)
        #expect(extra.currency == nil)
        #expect(extra.decimalPlaces == 2)
        #expect(extra.usedCreditsMinor == 1)
    }

    @Test func limitsAreCappedInResponseOrder() throws {
        // Unusable entries do not count towards the cap.
        let entries = (0..<1_000).map { #"{"kind": "k\#($0)", "percent": \#($0 % 100)}"# }
        let report = try decode(json: #"{"limits": ["junk", null, \#(entries.joined(separator: ","))]}"#)
        #expect(report.limits.count == UsageResponseDecoder.maxLimits)
        #expect(report.limits.map(\.id) == (0..<UsageResponseDecoder.maxLimits).map { "k\($0)" })
        #expect(UsageResponseDecoder.maxLimits == 32)
    }

    @Test func breakdownRowsAreDeduplicatedByKeyKeepingTheFirst() throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "seven_day_breakdown": {"rows": [
                    {"key": "chat", "display_name": "Chats", "percent": 10},
                    {"key": "claude_code", "percent": 20},
                    {"key": "chat", "display_name": "Impostor", "percent": 90},
                    {"key": "claude_code", "percent": 70}
                 ]}}
                """
        )
        let rows = try #require(report.weeklyBreakdown).rows
        #expect(rows.map(\.key) == ["chat", "claude_code"])
        #expect(rows.map(\.displayName) == ["Chats", "claude_code"])
        #expect(rows.map(\.percent) == [10, 20])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func breakdownRowsAreCappedAfterDeduplication() throws {
        // Duplicates of the first key do not use up the cap.
        let duplicates = (0..<50).map { _ in #"{"key": "r0", "percent": 1}"# }
        let distinct = (0..<1_000).map { #"{"key": "r\#($0)", "percent": 1}"# }
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "seven_day_breakdown": {"rows": [\((duplicates + distinct).joined(separator: ","))]}}
                """
        )
        let rows = try #require(report.weeklyBreakdown).rows
        #expect(rows.count == UsageResponseDecoder.maxBreakdownRows)
        #expect(rows.map(\.key) == (0..<UsageResponseDecoder.maxBreakdownRows).map { "r\($0)" })
        #expect(UsageResponseDecoder.maxBreakdownRows == 16)
    }

    @Test func breakdownWithoutUsableRowsIsNil() throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "seven_day_breakdown": {"as_of": "2026-10-21T17:55:11Z", "rows": []}}
                """
        )
        #expect(report.weeklyBreakdown == nil)

        let nameless = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 1}],
                 "seven_day_breakdown": {"rows": [{"key": "chat", "percent": 5}]}}
                """
        )
        let rows = try #require(nameless.weeklyBreakdown).rows
        #expect(rows == [BreakdownRow(key: "chat", displayName: "chat", percent: 5)])
    }

    @Test func unknownTopLevelAndEntryKeysAreIgnored() throws {
        let report = try decode(
            json: """
                {"limits": [{"kind": "session", "percent": 9, "brand_new_field": {"x": [1]}}],
                 "tangelo": null, "spend": {"used": {"amount_minor": 0}}, "weekly_scoped_shares": []}
                """
        )
        #expect(report.limits.count == 1)
        #expect(report.limits[0].kind == .session)
        #expect(report.limits[0].percentUsed == 9)
    }

    @Test func repeatedIDsGetNumericSuffixesInEncounterOrder() throws {
        func scopedOpus(_ percent: Int) -> String {
            """
            {"kind": "weekly_scoped", "percent": \(percent), "scope": {"model": {"display_name": "Opus"}}}
            """
        }
        let report = try decode(
            json: """
                {"limits": [
                    \(scopedOpus(10)),
                    {"kind": "session", "percent": 1},
                    \(scopedOpus(20)),
                    \(scopedOpus(30)),
                    {"kind": "session", "percent": 2}
                ]}
                """
        )
        #expect(
            report.limits.map(\.id) == [
                "weekly_scoped:Opus", "session", "weekly_scoped:Opus#2", "weekly_scoped:Opus#3", "session#2",
            ]
        )
        #expect(report.limits.map(\.percentUsed) == [10, 1, 20, 30, 2])
    }

    @Test func twoScopedEntriesWithTheSameNameGetDistinctIDs() throws {
        let report = try decode(
            json: """
                {"limits": [
                    {"kind": "weekly_scoped", "percent": 1, "scope": {"model": {"display_name": "Opus"}}},
                    {"kind": "weekly_scoped", "percent": 2, "scope": {"model": {"display_name": "Opus"}}}
                ]}
                """
        )
        #expect(report.limits.map(\.id) == ["weekly_scoped:Opus", "weekly_scoped:Opus#2"])
    }

    @Test func suffixedIDsNeverCollideWithLaterEntries() throws {
        let report = try decode(
            json: """
                {"limits": [
                    {"kind": "x", "percent": 1},
                    {"kind": "x", "percent": 2},
                    {"kind": "x#2", "percent": 3}
                ]}
                """
        )
        let ids = report.limits.map(\.id)
        #expect(ids.first == "x")
        #expect(Set(ids).count == 3)
    }

    @Test func legacyIDsStayUnsuffixed() throws {
        // Legacy keys are distinct by construction, so their ids are never suffixed.
        let report = try decode(
            json: #"{"seven_day_opus": {"utilization": 1}, "seven_day_sonnet": {"utilization": 2}}"#
        )
        #expect(report.limits.map(\.id) == ["weekly_scoped:Opus", "weekly_scoped:Sonnet"])
    }
}

@Suite struct UsageModelsTests {
    @Test func limitKindRoundTripsAsASingleString() throws {
        let kinds: [LimitKind] = [.session, .weeklyAll, .weeklyScoped, .other("monthly_pool")]
        let raws = ["session", "weekly_all", "weekly_scoped", "monthly_pool"]
        #expect(kinds.map(\.rawValue) == raws)
        #expect(raws.map { LimitKind(rawValue: $0) } == kinds)

        let encoded = try JSONEncoder().encode(kinds)
        #expect(String(decoding: encoded, as: UTF8.self) == #"["session","weekly_all","weekly_scoped","monthly_pool"]"#)
        #expect(try JSONDecoder().decode([LimitKind].self, from: encoded) == kinds)
    }

    @Test func usageLimitIDFollowsKindAndScope() {
        #expect(UsageLimit(kind: .session, percentUsed: 1).id == "session")
        #expect(UsageLimit(kind: .weeklyScoped, percentUsed: 1, scopeName: "Opus").id == "weekly_scoped:Opus")
        #expect(UsageLimit(kind: .other("x_y"), percentUsed: 1).id == "x_y")
        #expect(UsageLimit(id: "custom", kind: .session, percentUsed: 1).id == "custom")
    }

    @Test func percentRemainingIsComplementClampedToRange() {
        #expect(UsageLimit(kind: .session, percentUsed: 37.5).percentRemaining == 62.5)
        #expect(UsageLimit(kind: .session, percentUsed: 120).percentRemaining == 0)
        #expect(UsageLimit(kind: .session, percentUsed: -5).percentRemaining == 100)
    }

    @Test func reportAccessorsSelectByKind() {
        let session = UsageLimit(kind: .session, percentUsed: 1)
        let all = UsageLimit(kind: .weeklyAll, percentUsed: 2)
        let scoped = UsageLimit(kind: .weeklyScoped, percentUsed: 3, scopeName: "Opus")
        let other = UsageLimit(kind: .other("monthly_pool"), percentUsed: 4)
        let report = UsageReport(limits: [other, all, session, scoped])
        #expect(report.session == session)
        #expect(report.weeklyLimits == [all, scoped])
        #expect(UsageReport(limits: [other]).session == nil)
        #expect(UsageReport(limits: [other]).weeklyLimits.isEmpty)
        // Unknown kinds are kept for generic display, in response order.
        let second = UsageLimit(kind: .other("daily_api"), percentUsed: 5)
        #expect(UsageReport(limits: [other, all, session, second]).otherLimits == [other, second])
        #expect(report.otherLimits == [other])
        #expect(UsageReport(limits: [all, session, scoped]).otherLimits.isEmpty)
    }

    @Test func extraUsageShareAndDisplayability() {
        // The reported percentage wins and is clamped.
        #expect(ExtraUsage(isEnabled: true, percentUsed: 25).fractionUsed == 0.25)
        #expect(ExtraUsage(isEnabled: true, percentUsed: 140).fractionUsed == 1)
        // Without it, the amount spent over the monthly limit.
        #expect(ExtraUsage(isEnabled: true, monthlyLimitMinor: 5_000, usedCreditsMinor: 1_250).fractionUsed == 0.25)
        #expect(ExtraUsage(isEnabled: true, monthlyLimitMinor: 0, usedCreditsMinor: 1_250).fractionUsed == nil)
        #expect(ExtraUsage(isEnabled: true).fractionUsed == nil)

        // A saved snapshot keeps the share but no amounts: still worth a row, with only the percentage.
        let stripped = ExtraUsage(isEnabled: true, percentUsed: 24.8)
        #expect(stripped.hasDisplayableUsage)
        #expect(stripped.usedCreditsMinor == nil)
        #expect(ExtraUsage(isEnabled: true, usedCreditsMinor: 1_250).hasDisplayableUsage)
        #expect(!ExtraUsage(isEnabled: true).hasDisplayableUsage)
        #expect(!ExtraUsage(isEnabled: false, usedCreditsMinor: 1_250, percentUsed: 3).hasDisplayableUsage)
    }

    @Test func snapshotRoundTripsThroughCodable() throws {
        let report = try UsageResponseDecoder.decode(fixtureData("usage-live-2026-10-21"))
        let snapshot = UsageSnapshot(
            report: report,
            fetchedAt: Date(timeIntervalSince1970: 1_792_605_287.037),
            source: .claudeCodeCache
        )
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data) == snapshot)

        #expect(SnapshotSource.claudeCodeCache.rawValue == "claudeCodeCache")
        #expect(SnapshotSource.live.rawValue == "live")
        #expect(SnapshotSource.demo.rawValue == "demo")
    }
}
