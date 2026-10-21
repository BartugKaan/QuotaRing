import Foundation
import Testing

@testable import QuotaRingCore

@Suite struct QuotaFormatTests {
    private let locale = Locale(identifier: "en_US")
    private let now = Date(timeIntervalSince1970: 1_792_600_000)

    @Test func percent() {
        #expect(QuotaFormat.percent(71.6, locale: locale) == "72%")
        #expect(QuotaFormat.percent(0, locale: locale) == "0%")
        #expect(QuotaFormat.percent(100, locale: locale) == "100%")
        #expect(QuotaFormat.percent(71.6, locale: Locale(identifier: "tr_TR")) == "%72")
    }

    @Test func countdown() {
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(8040), from: now, locale: locale) == "2h 14m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(2700), from: now, locale: locale) == "45m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(20), from: now, locale: locale) == "<1m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(59), from: now, locale: locale) == "<1m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(60), from: now, locale: locale) == "1m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(7200), from: now, locale: locale) == "2h")
    }

    @Test func spokenCountdown() {
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(8040), from: now, locale: locale)
                == "2 hours, 14 minutes")
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(2700), from: now, locale: locale) == "45 minutes")
        #expect(QuotaFormat.spokenCountdown(to: now.addingTimeInterval(60), from: now, locale: locale) == "1 minute")
        #expect(QuotaFormat.spokenCountdown(to: now.addingTimeInterval(7200), from: now, locale: locale) == "2 hours")
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(184_800), from: now, locale: locale)
                == "2 days, 3 hours")
    }

    @Test func spokenCountdownUnderAMinuteOrInThePast() {
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(59), from: now, locale: locale)
                == "less than a minute")
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(-500), from: now, locale: locale)
                == "less than a minute")
        let french = Locale(identifier: "fr_FR")
        // No fr.lproj: the template falls back to English.
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(20), from: now, locale: french)
                == "less than a minute")
    }

    @Test func countdownInThePastIsLessThanAMinute() {
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(-500), from: now, locale: locale) == "<1m")
    }

    @Test func countdownSpansDays() {
        let interval: TimeInterval = 184_800  // 2 d 3 h 20 min
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(interval), from: now, locale: locale) == "2d 3h")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(97_200), from: now, locale: locale) == "1d 3h")
        // From a day on, the hours are rounded to the nearest one.
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(97_140), from: now, locale: locale) == "1d 3h")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(95_340), from: now, locale: locale) == "1d 2h")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(172_740), from: now, locale: locale) == "2d")
        // A zero second unit is left out.
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(86_400), from: now, locale: locale) == "1d")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(86_400 + 1_740), from: now, locale: locale) == "1d")
    }

    @Test func countdownRoundsDownToWholeMinutes() {
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(8_099), from: now, locale: locale) == "2h 14m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(119), from: now, locale: locale) == "1m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(86_399), from: now, locale: locale) == "23h 59m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(5_400), from: now, locale: locale) == "1h 30m")
    }

    @Test func countdownSurvivesAbsurdIntervals() {
        #expect(!QuotaFormat.countdown(to: .distantFuture, from: now, locale: locale).isEmpty)
        #expect(QuotaFormat.countdown(to: .distantPast, from: now, locale: locale) == "<1m")
    }

    @Test func turkishCountdownUsesUnambiguousUnits() {
        // DateComponentsFormatter wrote "2sa 14d" and "<1d" in Turkish, where "d" (dakika) reads like days.
        let turkish = Locale(identifier: "tr_TR")
        func countdown(_ seconds: TimeInterval) -> String {
            QuotaFormat.countdown(to: now.addingTimeInterval(seconds), from: now, locale: turkish)
        }
        #expect(countdown(8_040) == "2 sa 14 dk")
        #expect(countdown(2_700) == "45 dk")
        #expect(countdown(20) == "<1 dk")
        #expect(countdown(-500) == "<1 dk")
        #expect(countdown(97_200) == "1 g 3 sa")
        #expect(countdown(7_200) == "2 sa")
        #expect(countdown(172_800) == "2 g")
    }

    @Test func age() {
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-10), now: now, locale: locale) == "just now")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-59), now: now, locale: locale) == "just now")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-180), now: now, locale: locale) == "3 min ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-3599), now: now, locale: locale) == "59 min ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-3600), now: now, locale: locale) == "1 h ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-7 * 3600 - 59), now: now, locale: locale) == "7 h ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-86_400), now: now, locale: locale) == "1 d ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-3 * 86_400), now: now, locale: locale) == "3 d ago")
    }

    @Test func templatesFallBackToEnglishForLocalesWithoutTranslation() {
        // There is no fr.lproj, so French locales get the English templates (with French number formatting).
        let french = Locale(identifier: "fr_FR")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(20), from: now, locale: french) == "<1m")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(8040), from: now, locale: french) == "2h 14m")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-10), now: now, locale: french) == "just now")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-180), now: now, locale: french) == "3 min ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-2 * 3600), now: now, locale: french) == "2 h ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-2 * 86_400), now: now, locale: french) == "2 d ago")
    }

    @Test func turkishTemplates() {
        // Turkish has its own tr.lproj; the lookup follows the locale argument, not the language of the test process.
        let turkish = Locale(identifier: "tr_TR")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-10), now: now, locale: turkish) == "az önce")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-180), now: now, locale: turkish) == "3 dk önce")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-2 * 3600), now: now, locale: turkish) == "2 sa önce")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-3 * 86_400), now: now, locale: turkish) == "3 gün önce")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(20), from: now, locale: turkish) == "<1 dk")
        #expect(
            QuotaFormat.spokenCountdown(to: now.addingTimeInterval(20), from: now, locale: turkish)
                == "bir dakikadan az")
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(2700), from: now, locale: turkish) == "45 dk")
    }

    @Test func turkishTemplatesCoverEveryEnglishKeyWithTheSameFormatSpecifiers() throws {
        // A key missing from tr.lproj would silently fall back to English, so the two files are compared directly.
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/QuotaRingCore/Resources")
        func strings(_ language: String) throws -> [String: String] {
            let url = resources.appending(path: "\(language).lproj/Localizable.strings")
            return try #require(NSDictionary(contentsOf: url) as? [String: String])
        }
        let specifier = /%(?:\d+\$)?l{0,2}[@dsf]/
        let english = try strings("en")
        let turkish = try strings("tr")
        #expect(Set(turkish.keys) == Set(english.keys))
        for (key, template) in english {
            let expected = template.matches(of: specifier).map { String($0.output) }
            let actual = (turkish[key] ?? "").matches(of: specifier).map { String($0.output) }
            #expect(actual == expected, "format specifiers of \(key)")
        }
    }

    @Test func ageInTheFutureIsJustNow() {
        #expect(QuotaFormat.age(of: now.addingTimeInterval(30), now: now, locale: locale) == "just now")
    }

    @Test func tokens() {
        #expect(QuotaFormat.tokens(0, locale: locale) == "0")
        #expect(QuotaFormat.tokens(980, locale: locale) == "980")
        #expect(QuotaFormat.tokens(999, locale: locale) == "999")
        #expect(QuotaFormat.tokens(1_000, locale: locale) == "1K")
        #expect(QuotaFormat.tokens(34_200, locale: locale) == "34.2K")
        #expect(QuotaFormat.tokens(999_000, locale: locale) == "999K")
        #expect(QuotaFormat.tokens(1_000_000, locale: locale) == "1M")
        #expect(QuotaFormat.tokens(1_260_000, locale: locale) == "1.3M")
        #expect(QuotaFormat.tokens(12_000_000, locale: locale) == "12M")
    }

    @Test func tokensNeverShowFourDigitThousands() {
        // 999_950 rounds to 1000.0K at one fraction digit; it must roll over to millions instead.
        #expect(QuotaFormat.tokens(999_950, locale: locale) == "1M")
        #expect(QuotaFormat.tokens(999_949, locale: locale) == "999.9K")
    }

    @Test func tokensUseLocaleDecimalSeparator() {
        #expect(QuotaFormat.tokens(34_200, locale: Locale(identifier: "tr_TR")) == "34,2K")
    }
}
