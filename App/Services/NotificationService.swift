import AppKit
import QuotaRingCore
import UserNotifications
import os

private let notificationLog = Logger(subsystem: "io.github.bartugkaan.QuotaRing", category: "notifications")

/// Whether macOS lets QuotaRing show notifications.
enum NotificationPermission: Sendable, Equatable {
    /// macOS has not asked the user yet.
    case notDetermined
    /// The user said no (or turned notifications off for QuotaRing in System Settings).
    case denied
    case allowed
}

/// Shows local notifications for the threshold events ``AppModel`` detects.
///
/// Everything stays on this Mac: the notifications are built from the usage snapshot and posted to
/// `UNUserNotificationCenter`; nothing is sent anywhere. The service never asks for permission by itself while posting.
/// Only ``requestAuthorizationIfNeeded()`` does, and it is called when the user agrees to notifications (onboarding, or
/// turning a notification setting on).
///
/// ## Isolation
///
/// The UserNotifications objects (`UNUserNotificationCenter`, `UNNotificationSettings`, `UNNotificationRequest`, ...)
/// are not `Sendable` in every SDK the project builds with (Xcode 16.4's, for one), and their async methods run off the
/// main actor. So none of them is stored in this main-actor class or passed in or out of an `await` here. Each async
/// call lives in a `nonisolated static` helper that gets `UNUserNotificationCenter.current()` itself, builds what it
/// needs from `Sendable` inputs (strings, dates, events) and hands back only `Sendable` values (`Bool`,
/// `UNAuthorizationStatus`). `current()` is the app's one shared center, so every helper talks to the same center.
@MainActor
final class NotificationService: NSObject, UsageNotifier {
    /// Whether ``requestAuthorizationIfNeeded()`` may show the system permission prompt. `false` in demo mode, which
    /// never touches real notification permission.
    let allowsPermissionRequests: Bool

    /// - Parameter center: Only used here, to register `self` as its delegate (a synchronous call). Every async call
    ///   goes through the static helpers below, which use `UNUserNotificationCenter.current()`, so a different
    ///   `center` would not receive any notifications.
    init(allowsPermissionRequests: Bool = true, center: UNUserNotificationCenter = .current()) {
        self.allowsPermissionRequests = allowsPermissionRequests
        super.init()
        // Without a delegate macOS would not show banners while QuotaRing is the active app (its Settings window is).
        center.delegate = self
    }

    // MARK: - UsageNotifier

    func post(_ events: [ThresholdEvent], snapshot: UsageSnapshot) {
        guard !events.isEmpty else { return }
        let now = Date()
        let session = snapshot.session(at: now)
        // Only Sendable values go into the task; the notification objects are created and used inside `deliver`.
        Task {
            await Self.deliver(events, session: session, now: now)
        }
    }

    // MARK: - Permission

    /// The permission as macOS currently has it; the user can change it in System Settings at any time.
    func permission() async -> NotificationPermission {
        Self.permission(of: await Self.currentAuthorizationStatus())
    }

    /// Shows the system permission prompt, but only when macOS has not asked yet (and never when
    /// ``allowsPermissionRequests`` is `false`). Returns the permission afterwards.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> NotificationPermission {
        let current = await permission()
        guard current == .notDetermined, allowsPermissionRequests else { return current }
        do {
            _ = try await Self.requestAuthorization()
        } catch {
            notificationLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
        }
        return await permission()
    }

    /// Opens System Settings → Notifications.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private nonisolated static func permission(of status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }

    // MARK: - UserNotifications calls
    //
    // Nonisolated on purpose, see "Isolation" above: the center and every other non-Sendable object stay inside one
    // function, and only Sendable values cross the boundary to the main actor.

    /// Reads only the status. `UNNotificationSettings` is not `Sendable` in the Xcode 16 SDK, so it must not leave
    /// this nonisolated context.
    private nonisolated static func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Shows the system permission prompt. Returns whether the user allowed notifications.
    private nonisolated static func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
    }

    /// Posts one notification per event, unless macOS has not authorized notifications (then it drops them silently:
    /// asking is the job of onboarding and Settings).
    private nonisolated static func deliver(_ events: [ThresholdEvent], session: UsageLimit?, now: Date) async {
        guard permission(of: await currentAuthorizationStatus()) == .allowed else { return }
        let center = UNUserNotificationCenter.current()
        for event in events {
            do {
                try await center.add(request(for: event, session: session, now: now))
            } catch {
                notificationLog.error("Could not post a notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Content

    /// The notification for one event. `session` supplies the remaining share and the reset time.
    nonisolated static func request(
        for event: ThresholdEvent, session: UsageLimit?, now: Date
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        // One thread, so macOS stacks QuotaRing's notifications together.
        content.threadIdentifier = "session"
        let identifier: String
        switch event {
        case .crossed(let threshold):
            identifier = "session-threshold-\(threshold)"
            let used = QuotaFormat.percent(Double(threshold))
            content.title = String(
                localized: "Claude session at \(used)",
                comment:
                    "Notification title when 5-hour session usage crossed a threshold; the argument is a percentage")
            if let session {
                let remaining = QuotaFormat.percent(session.percentRemaining)
                if let resetsAt = session.resetsAt {
                    let countdown = QuotaFormat.countdown(to: resetsAt, from: now)
                    content.body = String(
                        localized: "About \(remaining) left · resets in \(countdown)",
                        comment: "Notification body; a percentage and a duration such as 1h 22m")
                } else {
                    content.body = String(
                        localized: "About \(remaining) left",
                        comment: "Notification body; the argument is a percentage")
                }
            }
        case .reset:
            identifier = "session-reset"
            content.title = String(
                localized: "Your Claude session limit has reset",
                comment: "Notification title when a new 5-hour session window began")
        }
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show the banner even when QuotaRing is the frontmost app.
    ///
    /// `nonisolated`: macOS calls the delegate on its own queue, and the body touches no main-actor state, so the
    /// non-`Sendable` `center` and `notification` arguments are never used here (or sent anywhere).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
