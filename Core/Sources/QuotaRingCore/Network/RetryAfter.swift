import Foundation

/// Parser for the HTTP `Retry-After` header.
public enum RetryAfter {
    /// Seconds to wait according to `header`, or `nil` when it is absent or unusable.
    ///
    /// Accepts delta-seconds (a non-negative integer) or an IMF-fixdate such as `Wed, 21 Oct 2026 07:28:00 GMT`, which
    /// is measured against `now` and clamped to zero when it lies in the past.
    public static func parse(_ header: String?, now: Date) -> TimeInterval? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        if value.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return Int(value).map(TimeInterval.init)
        }

        guard let date = httpDateFormatter().date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func httpDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }
}
