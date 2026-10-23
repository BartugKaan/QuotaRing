import Foundation

/// Whether anybody can be looking at the Mac, from the signals the system gives: the displays going to sleep, the user's
/// session going to the background (fast user switching) and the screen being locked.
///
/// While nobody is there, asking Anthropic or running Claude Code every few minutes is wasted work: the numbers cannot
/// be seen. The app pauses its Live and auto-refresh loops then, and starts them again, with an immediate check of
/// what is due, when somebody is back. This type only holds the state and decides when it changes; the system
/// notifications and the loops are the app's.
///
/// The three conditions are independent: a locked screen stays locked while the displays wake up for the lock screen,
/// and the user is back only when none of them applies.
public struct UserPresence: Equatable, Sendable {
    /// What the system reported, or what the user did.
    public enum Signal: Equatable, Sendable {
        /// All displays went to sleep.
        case displaysSlept
        /// The displays woke up.
        case displaysWoke
        /// The user's session went to the background (another user's session became the active one).
        case sessionResigned
        /// The user's session is the active one again.
        case sessionBecameActive
        /// The screen was locked.
        case screenLocked
        /// The screen was unlocked.
        case screenUnlocked
        /// The user used the app (opened its popover or pressed Refresh). That is only possible with awake displays, an
        /// active session and an unlocked screen, so it ends every condition. It heals a missed "woke" or "unlocked".
        case userInteracted
    }

    /// What a signal came to.
    public enum Change: Equatable, Sendable {
        /// Away or present as before.
        case none
        /// Somebody was there and now nobody is.
        case wentAway
        /// Nobody was there and now somebody is.
        case cameBack
    }

    public private(set) var displaysAreAsleep = false
    public private(set) var sessionIsInactive = false
    public private(set) var screenIsLocked = false

    /// Whether nobody can be looking: the displays are asleep, the session is in the background or the screen is locked.
    public var isAway: Bool {
        displaysAreAsleep || sessionIsInactive || screenIsLocked
    }

    /// The conditions that hold, for logs: "displays asleep, screen locked". Empty when somebody is there.
    public var logName: String {
        [
            displaysAreAsleep ? "displays asleep" : nil,
            sessionIsInactive ? "session inactive" : nil,
            screenIsLocked ? "screen locked" : nil,
        ]
        .compactMap { $0 }.joined(separator: ", ")
    }

    /// At the start nobody is assumed away: the app starts at login or from the menu bar of a user who is there.
    public init() {}

    /// Applies `signal` and reports whether somebody left or came back because of it. A signal that repeats what is
    /// already known changes nothing.
    @discardableResult
    public mutating func apply(_ signal: Signal) -> Change {
        let wasAway = isAway
        switch signal {
        case .displaysSlept: displaysAreAsleep = true
        case .displaysWoke: displaysAreAsleep = false
        case .sessionResigned: sessionIsInactive = true
        case .sessionBecameActive: sessionIsInactive = false
        case .screenLocked: screenIsLocked = true
        case .screenUnlocked: screenIsLocked = false
        case .userInteracted:
            displaysAreAsleep = false
            sessionIsInactive = false
            screenIsLocked = false
        }
        switch (wasAway, isAway) {
        case (false, true): return .wentAway
        case (true, false): return .cameBack
        default: return .none
        }
    }
}
