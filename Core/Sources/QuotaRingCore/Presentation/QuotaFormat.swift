import Foundation

/// Locale-aware formatting of the numbers and times the UI shows.
public enum QuotaFormat {
    /// A percentage given on a `0...100` scale, for example `71.6` becomes `"72%"` (`"%72"` in Turkish).
    ///
    /// Ties round half to even, which is `NumberFormatter`'s default and is intentional: `71.5` shows as `72%` used and
    /// `28.5` as `28%` remaining, so a used and a remaining figure for the same limit still add up to 100.
    public static func percent(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value / 100)) ?? "\(Int(value.rounded()))%"
    }

    /// The time from `from` until `to` in its two largest units: `"1d 3h"`, `"2h 14m"`, `"45m"` (Turkish `"1 g 3 sa"`,
    /// `"2 sa 14 dk"`, `"45 dk"`). A zero second unit is left out (`"2h"`, `"2d"`). Under a day the time is rounded
    /// down to whole minutes; from a day on, to the nearest hour (as `DateComponentsFormatter` did before). Anything
    /// under a minute, including a time already past, is `"<1m"` (`"<1 dk"`).
    ///
    /// The unit names come from QuotaRing's own templates rather than `DateComponentsFormatter`, whose abbreviated
    /// Turkish style writes minutes as "d" ("2sa 14d"), which reads like days.
    public static func countdown(to: Date, from: Date, locale: Locale = .current) -> String {
        let interval = to.timeIntervalSince(from)
        guard interval >= 60, interval.isFinite else { return template("format.lessThanMinute", locale: locale) }

        let totalMinutes = Int(min(interval, 1e15) / 60)
        let minutes = totalMinutes % 60
        var hours = totalMinutes % 1440 / 60
        var days = totalMinutes / 1440
        if days > 0, minutes >= 30 {
            hours += 1
            if hours == 24 {
                days += 1
                hours = 0
            }
        }

        func format(_ key: String, _ arguments: Int...) -> String {
            String(
                format: template(key, locale: locale), locale: locale, arguments: arguments.map { $0 as any CVarArg })
        }
        if days > 0 {
            return hours > 0 ? format("format.countdown.dayHour", days, hours) : format("format.countdown.day", days)
        }
        if hours > 0 {
            return minutes > 0
                ? format("format.countdown.hourMinute", hours, minutes) : format("format.countdown.hour", hours)
        }
        return format("format.countdown.minute", minutes)
    }

    /// The same duration as ``countdown(to:from:locale:)``, spelled out for speech, for example
    /// `"2 hours, 14 minutes"` (the compact `"2h 14m"` reads poorly aloud). Under a minute, including a time already
    /// past, it is `"less than a minute"`.
    public static func spokenCountdown(to: Date, from: Date, locale: Locale = .current) -> String {
        let interval = to.timeIntervalSince(from)
        guard interval >= 60 else { return template("format.spokenLessThanMinute", locale: locale) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? countdown(to: to, from: from, locale: locale)
    }

    /// How long ago `date` was, as of `now`: `"just now"`, `"3 min ago"`, `"2 h ago"` or `"4 d ago"`.
    /// A date in the future counts as just now.
    public static func age(of date: Date, now: Date, locale: Locale = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            return template("format.justNow", locale: locale)
        }
        let key: String
        let count: Int
        if seconds < 3600 {
            key = "format.minutesAgo"
            count = Int(seconds / 60)
        } else if seconds < 86_400 {
            key = "format.hoursAgo"
            count = Int(seconds / 3600)
        } else {
            key = "format.daysAgo"
            count = Int(seconds / 86_400)
        }
        return String(format: template(key, locale: locale), locale: locale, count)
    }

    /// A compact token count: `"980"`, `"34.2K"`, `"1.3M"`. A trailing `.0` is dropped.
    public static func tokens(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        formatter.usesGroupingSeparator = false

        func scaled(_ divisor: Double, suffix: String) -> String {
            let number = formatter.string(from: NSNumber(value: Double(value) / divisor)) ?? "\(value)"
            return number + suffix
        }

        let magnitude = abs(value)
        if magnitude < 1_000 {
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
        // 999_950 and above would round to "1000K" at one fraction digit, so they move up to millions.
        if magnitude < 1_000_000 && (Double(magnitude) / 100).rounded() < 10_000 {
            return scaled(1_000, suffix: "K")
        }
        return scaled(1_000_000, suffix: "M")
    }

    /// The string template for `key` in the language of `locale`.
    ///
    /// `String(localized:bundle:)` would pick the language from the process's preferred languages and ignore the
    /// `locale` argument. Looking in the locale's own `.lproj` keeps a format call self-consistent. Languages without
    /// an `.lproj`, and keys missing from one, fall back to English.
    private static func template(_ key: String, locale: Locale) -> String {
        let missing = "\u{0}missing"
        if let code = locale.language.languageCode?.identifier, let bundle = languageBundle(code) {
            let value = bundle.localizedString(forKey: key, value: missing, table: nil)
            if value != missing { return value }
        }
        return languageBundle("en")?.localizedString(forKey: key, value: nil, table: nil) ?? key
    }

    private static func languageBundle(_ code: String) -> Bundle? {
        Bundle.module.path(forResource: code, ofType: "lproj").flatMap { Bundle(path: $0) }
    }
}
