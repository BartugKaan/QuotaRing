import Foundation

/// Parses the date representations the usage endpoint is known (or likely) to produce.
///
/// - ISO 8601 strings with any number of fractional-second digits (the live API sends microseconds) and an offset
///   written as `Z`, `±HH:MM`, `±HHMM` or `±HH`. A string without an offset is read as UTC.
/// - Numbers, read as seconds since the Unix epoch and accepted only from `0` (1970-01-01) through `4_102_444_800`
///   (2100-01-01), inclusive. This rejects negative values and absurdly large ones, including epoch milliseconds
///   mistaken for seconds.
///
/// Everything else (`nil`, `NSNull`, booleans, malformed strings, out-of-range numbers, other types) yields `nil`.
public enum FlexibleDate {
    private static let epochRange: ClosedRange<Double> = 0...4_102_444_800

    public static func parse(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if let text = value as? String {
            return parseISO8601(text)
        }
        if let seconds = JSONValue.double(value), epochRange.contains(seconds) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    // `ISO8601DateFormatter` rejects some fractional-second widths, so the string is parsed by hand and the instant
    // is computed from a proleptic Gregorian civil date.
    private static func parseISO8601(_ text: String) -> Date? {
        var cursor = Cursor(bytes: Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))

        guard
            let year = cursor.number(digits: 4), cursor.consume("-"),
            let month = cursor.number(digits: 2), cursor.consume("-"),
            let day = cursor.number(digits: 2),
            cursor.consumeAny(of: "T", "t", " "),
            let hour = cursor.number(digits: 2), cursor.consume(":"),
            let minute = cursor.number(digits: 2)
        else { return nil }

        var second = 0
        var fraction = 0.0
        if cursor.consume(":") {
            guard let parsedSecond = cursor.number(digits: 2) else { return nil }
            second = parsedSecond
            if cursor.consumeAny(of: ".", ",") {
                guard let digits = cursor.digitRun(), let parsedFraction = Double("0." + digits) else { return nil }
                fraction = parsedFraction
            }
        }

        var offsetSeconds = 0
        if cursor.consumeAny(of: "Z", "z") {
            offsetSeconds = 0
        } else if let sign = cursor.signOfOffset() {
            guard let offsetHours = cursor.number(digits: 2) else { return nil }
            var offsetMinutes = 0
            if cursor.consume(":") {
                guard let parsedMinutes = cursor.number(digits: 2) else { return nil }
                offsetMinutes = parsedMinutes
            } else if !cursor.isAtEnd {
                guard let parsedMinutes = cursor.number(digits: 2) else { return nil }
                offsetMinutes = parsedMinutes
            }
            guard offsetHours <= 23, offsetMinutes <= 59 else { return nil }
            offsetSeconds = sign * (offsetHours * 3600 + offsetMinutes * 60)
        }

        guard
            cursor.isAtEnd,
            (1...12).contains(month),
            (1...daysInMonth(year: year, month: month)).contains(day),
            hour <= 23, minute <= 59, second <= 60
        else { return nil }

        let secondsAtMidnight = daysSinceEpoch(year: year, month: month, day: day) * 86_400
        let secondsIntoDay = hour * 3600 + minute * 60 + second
        let wholeSeconds = secondsAtMidnight + secondsIntoDay - offsetSeconds
        return Date(timeIntervalSince1970: Double(wholeSeconds) + fraction)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Days from 1970-01-01 to the given civil date (Howard Hinnant's `days_from_civil`).
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private struct Cursor {
        let bytes: [UInt8]
        private var index = 0

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        var isAtEnd: Bool { index >= bytes.count }

        mutating func consume(_ character: Unicode.Scalar) -> Bool {
            guard index < bytes.count, bytes[index] == UInt8(ascii: character) else { return false }
            index += 1
            return true
        }

        mutating func consumeAny(of characters: Unicode.Scalar...) -> Bool {
            for character in characters where consume(character) {
                return true
            }
            return false
        }

        /// Consumes `+` or `-` and returns the sign as `1` or `-1`.
        mutating func signOfOffset() -> Int? {
            if consume("+") { return 1 }
            if consume("-") { return -1 }
            return nil
        }

        /// Consumes exactly `digits` ASCII digits.
        mutating func number(digits: Int) -> Int? {
            guard index + digits <= bytes.count else { return nil }
            var result = 0
            for offset in 0..<digits {
                let byte = bytes[index + offset]
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                result = result * 10 + Int(byte - UInt8(ascii: "0"))
            }
            index += digits
            return result
        }

        /// Consumes one or more ASCII digits and returns them as text.
        mutating func digitRun() -> String? {
            let start = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            guard index > start else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
