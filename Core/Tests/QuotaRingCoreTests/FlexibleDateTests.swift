import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct FlexibleDateTests {
    private func seconds(_ value: Any?) -> Double? {
        FlexibleDate.parse(value)?.timeIntervalSince1970
    }

    /// Whether `value` parses to within 0.1 ms of `expected` seconds since the epoch.
    private func parses(_ value: Any?, near expected: Double) -> Bool {
        guard let actual = seconds(value) else { return false }
        return abs(actual - expected) < 0.0001
    }

    @Test func flexibleDateParses() {
        // Microseconds (the live API shape), milliseconds, no fraction.
        #expect(parses("2026-10-21T22:50:00.192966+00:00", near: 1_792_623_000.192966))
        #expect(parses("2026-10-21T22:50:00.192Z", near: 1_792_623_000.192))
        #expect(seconds("2026-10-21T22:50:00+00:00") == 1_792_623_000)
        #expect(seconds("2026-10-21T22:50:00Z") == 1_792_623_000)

        // Offsets move the instant: 22:50 at +03:00 is 19:50 UTC.
        #expect(parses("2026-10-21T22:50:00+03:00", near: 1_792_612_200))
        #expect(parses("2026-10-21T22:50:00-05:30", near: 1_792_642_800))
        #expect(parses("2026-10-21T22:50:00+0300", near: 1_792_612_200))
        #expect(parses("2026-10-21T22:50:00+03", near: 1_792_612_200))
        #expect(parses("2026-10-21T22:50:00", near: 1_792_623_000))

        // Numbers are epoch seconds.
        #expect(seconds(1_792_623_000) == 1_792_623_000)
        #expect(seconds(1_792_623_000.5) == 1_792_623_000.5)
        #expect(seconds(NSNumber(value: 42)) == 42)
        #expect(seconds(Int64(7)) == 7)
    }

    @Test func fractionOfAnyLength() {
        #expect(parses("2026-10-21T22:50:00.5Z", near: 1_792_623_000.5))
        #expect(parses("2026-10-21T22:50:00.1929661Z", near: 1_792_623_000.192966))
        #expect(parses("2026-10-21T22:50:00.192966123Z", near: 1_792_623_000.192966))
        #expect(parses("2026-10-21T22:50:00.192966123456789Z", near: 1_792_623_000.192966))
        #expect(parses("2026-10-21T22:50:00,25Z", near: 1_792_623_000.25))
    }

    @Test func agreesWithGregorianCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let cases: [(String, DateComponents)] = [
            ("1969-12-31T23:59:59Z", DateComponents(year: 1969, month: 12, day: 31, hour: 23, minute: 59, second: 59)),
            ("1970-01-01T00:00:00Z", DateComponents(year: 1970, month: 1, day: 1)),
            ("2000-02-29T12:00:00Z", DateComponents(year: 2000, month: 2, day: 29, hour: 12)),
            ("2024-02-29T00:00:00Z", DateComponents(year: 2024, month: 2, day: 29)),
            ("2100-03-01T00:00:00Z", DateComponents(year: 2100, month: 3, day: 1)),
            ("2026-12-31T23:59:59Z", DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59)),
        ]
        for (text, components) in cases {
            let expected = try #require(calendar.date(from: components))
            #expect(FlexibleDate.parse(text) == expected, "\(text)")
        }
    }

    @Test func garbageIsNil() {
        #expect(FlexibleDate.parse(nil) == nil)
        #expect(FlexibleDate.parse(NSNull()) == nil)
        #expect(FlexibleDate.parse("garbage") == nil)
        #expect(FlexibleDate.parse("") == nil)
        #expect(FlexibleDate.parse("   ") == nil)
        #expect(FlexibleDate.parse("2026-10-21") == nil)
        #expect(FlexibleDate.parse("2026-13-01T00:00:00Z") == nil)
        #expect(FlexibleDate.parse("2026-02-30T00:00:00Z") == nil)
        #expect(FlexibleDate.parse("2026-10-21T25:00:00Z") == nil)
        #expect(FlexibleDate.parse("2026-10-21T22:50:00.Z") == nil)
        #expect(FlexibleDate.parse("2026-10-21T22:50:00+03:99") == nil)
        #expect(FlexibleDate.parse("2026-10-21T22:50:00Zjunk") == nil)
        #expect(FlexibleDate.parse(true) == nil)
        #expect(FlexibleDate.parse(NSNumber(value: false)) == nil)
        #expect(FlexibleDate.parse(Double.nan) == nil)
        #expect(FlexibleDate.parse(Double.infinity) == nil)
        #expect(FlexibleDate.parse(["a": 1]) == nil)
        #expect(FlexibleDate.parse([1, 2]) == nil)
    }
}
