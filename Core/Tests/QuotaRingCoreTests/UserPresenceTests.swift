import Testing

@testable import QuotaRingCore

@Suite struct UserPresenceTests {
    @Test func startsPresent() {
        let presence = UserPresence()
        #expect(!presence.isAway)
        #expect(presence.logName.isEmpty)
    }

    @Test(arguments: [
        (UserPresence.Signal.displaysSlept, UserPresence.Signal.displaysWoke),
        (.sessionResigned, .sessionBecameActive),
        (.screenLocked, .screenUnlocked),
    ])
    func eachConditionSendsTheUserAwayAndBringsThemBack(
        leaving: UserPresence.Signal, returning: UserPresence.Signal
    ) {
        var presence = UserPresence()
        #expect(presence.apply(leaving) == .wentAway)
        #expect(presence.isAway)
        #expect(presence.apply(returning) == .cameBack)
        #expect(!presence.isAway)
    }

    @Test func aSignalThatRepeatsWhatIsKnownChangesNothing() {
        var presence = UserPresence()
        #expect(presence.apply(.displaysSlept) == .wentAway)
        #expect(presence.apply(.displaysSlept) == .none)
        #expect(presence.apply(.displaysWoke) == .cameBack)
        #expect(presence.apply(.displaysWoke) == .none)
        // Coming back when nobody left is not news either.
        #expect(presence.apply(.screenUnlocked) == .none)
        #expect(presence.apply(.sessionBecameActive) == .none)
        #expect(presence == UserPresence())
    }

    @Test func theUserIsBackOnlyWhenNoConditionHoldsAnyMore() {
        var presence = UserPresence()
        #expect(presence.apply(.screenLocked) == .wentAway)
        // The displays go to sleep on the lock screen: still away, and not a new departure.
        #expect(presence.apply(.displaysSlept) == .none)
        // They wake up for the lock screen: still locked.
        #expect(presence.apply(.displaysWoke) == .none)
        #expect(presence.isAway)
        #expect(presence.apply(.screenUnlocked) == .cameBack)
        #expect(!presence.isAway)
    }

    @Test func aSessionInTheBackgroundStaysAwayWhileTheDisplaysWake() {
        var presence = UserPresence()
        #expect(presence.apply(.sessionResigned) == .wentAway)
        #expect(presence.apply(.displaysSlept) == .none)
        #expect(presence.apply(.displaysWoke) == .none)
        #expect(presence.isAway)
        #expect(presence.apply(.sessionBecameActive) == .cameBack)
    }

    @Test func allThreeConditionsMustEndBeforeTheUserIsBack() {
        var presence = UserPresence()
        presence.apply(.displaysSlept)
        presence.apply(.sessionResigned)
        presence.apply(.screenLocked)
        #expect(presence.logName == "displays asleep, session inactive, screen locked")

        #expect(presence.apply(.screenUnlocked) == .none)
        #expect(presence.apply(.displaysWoke) == .none)
        #expect(presence.logName == "session inactive")
        #expect(presence.apply(.sessionBecameActive) == .cameBack)
        #expect(presence.logName.isEmpty)
    }

    @Test func usingTheAppEndsEveryCondition() {
        // A missed "woke" or "unlocked" must not leave the loops paused for good: clicking the menu bar item proves
        // that somebody is there.
        var presence = UserPresence()
        presence.apply(.displaysSlept)
        presence.apply(.screenLocked)
        presence.apply(.sessionResigned)

        #expect(presence.apply(.userInteracted) == .cameBack)
        #expect(presence == UserPresence())
        #expect(presence.apply(.userInteracted) == .none)
    }

    @Test func aDepartureAfterTheAppWasUsedIsNewAgain() {
        var presence = UserPresence()
        presence.apply(.userInteracted)
        #expect(presence.apply(.screenLocked) == .wentAway)
    }

    // MARK: - Which loops may run

    @Test func automaticRequestsMayRunOnlyWhenAwakeOnlineAndSomebodyIsThere() {
        let present = UserPresence()
        var away = UserPresence()
        away.apply(.displaysSlept)

        #expect(RefreshPlanner.automaticRequestsMayRun(isAsleep: false, isOnline: true, presence: present))
        #expect(!RefreshPlanner.automaticRequestsMayRun(isAsleep: true, isOnline: true, presence: present))
        #expect(!RefreshPlanner.automaticRequestsMayRun(isAsleep: false, isOnline: false, presence: present))
        #expect(!RefreshPlanner.automaticRequestsMayRun(isAsleep: false, isOnline: true, presence: away))
        #expect(!RefreshPlanner.automaticRequestsMayRun(isAsleep: true, isOnline: false, presence: away))
    }

    @Test(arguments: [
        UserPresence.Signal.displaysSlept, .sessionResigned, .screenLocked,
    ])
    func eachWayOfBeingAwayStopsTheLoops(signal: UserPresence.Signal) {
        var presence = UserPresence()
        presence.apply(signal)
        #expect(!RefreshPlanner.automaticRequestsMayRun(isAsleep: false, isOnline: true, presence: presence))
    }
}
