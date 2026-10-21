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

    /// The time from `from` until `to` as days, hours and minutes (at most two units), for example `"2h 14m"`.
    /// Anything under a minute, including a time already past, is `"<1m"`.
    public static func countdown(to: Date, from: Date, locale: Locale = .current) -> String {
        let interval = to.timeIntervalSince(from)
        let lessThanMinute = template("format.lessThanMinute", locale: locale)
        guard interval >= 60 else { return lessThanMinute }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? lessThanMinute
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
