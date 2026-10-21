import Foundation

/// Something the notification logic should react to.
public enum ThresholdEvent: Hashable, Sendable {
    /// Usage reached the given percent threshold for the first time in the current window.
    case crossed(Int)
    /// A new usage window began after the previous one's reset time had passed.
    case reset
}

/// Turns a stream of usage readings into one-shot threshold events.
///
/// A window is identified by its reset time rounded to the nearest minute, because the endpoint reports the same
/// instant with a few hundred microseconds of jitter between calls. Each threshold fires at most once per window.
/// The tracker is `Codable` so the app can persist it and avoid repeating notifications after a restart.
public struct ThresholdTracker: Codable, Equatable, Sendable {
    /// The current window's key: epoch minutes of its reset time.
    private var windowKey: Int?
    /// Thresholds already announced in the current window.
    private var fired: Set<Int>

    public init() {
        windowKey = nil
        fired = []
    }

    /// Records a reading and returns the events it caused, in order: ``ThresholdEvent/reset`` first (if any), then
    /// ``ThresholdEvent/crossed(_:)`` for each newly exceeded threshold in ascending order.
    ///
    /// Readings without a reset time are ignored. On the first reading, every threshold that is already exceeded
    /// fires once. A reset already announced by ``observeWindowEnd(now:)`` is not announced again.
    public mutating func observe(
        percentUsed: Double,
        resetsAt: Date?,
        thresholds: [Int],
        now: Date
    ) -> [ThresholdEvent] {
        guard let resetsAt else { return [] }
        let key = Self.key(for: resetsAt)
        var events: [ThresholdEvent] = []

        if key != windowKey {
            if let previous = windowKey, Self.date(for: previous) <= now {
                events.append(.reset)
            }
            windowKey = key
            fired = []
        }

        for threshold in Set(thresholds).sorted() where percentUsed >= Double(threshold) && !fired.contains(threshold) {
            fired.insert(threshold)
            events.append(.crossed(threshold))
        }
        return events
    }

    /// Notices that the current window's reset time has passed, without waiting for a new reading.
    ///
    /// Call it as time passes (the app does every 30 s): new readings may arrive much later, or, for someone who only
    /// reads Claude Code's cache, not until the next time Claude Code runs. When the window's reset time has passed,
    /// returns ``ThresholdEvent/reset`` once and closes the window, so the next reading starts a new one without
    /// announcing the reset again and with every threshold armed. Returns nothing otherwise.
    public mutating func observeWindowEnd(now: Date) -> [ThresholdEvent] {
        guard let windowKey, Self.date(for: windowKey) <= now else { return [] }
        self.windowKey = nil
        fired = []
        return [.reset]
    }

    private static func key(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded())
    }

    private static func date(for key: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(key) * 60)
    }
}
