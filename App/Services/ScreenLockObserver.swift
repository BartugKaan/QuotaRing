import Foundation
import QuotaRingCore

/// Reports the screen being locked and unlocked.
///
/// macOS posts `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` to the distributed notification center when
/// the lock screen appears and goes away. They are not documented, but they have been the same for many releases and
/// there is no public API for it. Nothing depends on them: if they stop arriving, the displays going to sleep (a
/// public notification) still pause the app's polling, and using the app ends a stale "locked" (see
/// ``UserPresence/Signal/userInteracted``). Only the fact is read; the notifications carry nothing else.
///
/// The observer asks for immediate delivery. Without it the center holds notifications back for an app that is not
/// active, and a menu bar app almost never is.
final class ScreenLockObserver: NSObject, @unchecked Sendable {
    private static let lockedName = Notification.Name("com.apple.screenIsLocked")
    private static let unlockedName = Notification.Name("com.apple.screenIsUnlocked")

    private let handler: @MainActor @Sendable (UserPresence.Signal) -> Void

    init(handler: @escaping @MainActor @Sendable (UserPresence.Signal) -> Void) {
        self.handler = handler
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self, selector: #selector(screenWasLocked(_:)), name: Self.lockedName, object: nil,
            suspensionBehavior: .deliverImmediately)
        center.addObserver(
            self, selector: #selector(screenWasUnlocked(_:)), name: Self.unlockedName, object: nil,
            suspensionBehavior: .deliverImmediately)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func screenWasLocked(_ notification: Notification) {
        let handler = handler
        Task { @MainActor in handler(.screenLocked) }
    }

    @objc private func screenWasUnlocked(_ notification: Notification) {
        let handler = handler
        Task { @MainActor in handler(.screenUnlocked) }
    }
}
