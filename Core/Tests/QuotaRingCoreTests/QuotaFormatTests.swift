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

    @Test func countdownInThePastIsLessThanAMinute() {
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(-500), from: now, locale: locale) == "<1m")
    }

    @Test func countdownSpansDays() {
        let interval: TimeInterval = 184_800  // 2 d 3 h 20 min
        #expect(QuotaFormat.countdown(to: now.addingTimeInterval(interval), from: now, locale: locale) == "2d 3h")
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
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-10), now: now, locale: french) == "just now")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-180), now: now, locale: french) == "3 min ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-2 * 3600), now: now, locale: french) == "2 h ago")
        #expect(QuotaFormat.age(of: now.addingTimeInterval(-2 * 86_400), now: now, locale: french) == "2 d ago")
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
