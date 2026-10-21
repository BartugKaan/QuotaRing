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
@MainActor
final class NotificationService: NSObject, UsageNotifier {
    private let center: UNUserNotificationCenter
    /// Whether ``requestAuthorizationIfNeeded()`` may show the system permission prompt. `false` in demo mode, which
    /// never touches real notification permission.
    let allowsPermissionRequests: Bool

    init(allowsPermissionRequests: Bool = true, center: UNUserNotificationCenter = .current()) {
        self.allowsPermissionRequests = allowsPermissionRequests
        self.center = center
        super.init()
        // Without a delegate macOS would not show banners while QuotaRing is the active app (its Settings window is).
        center.delegate = self
    }

    // MARK: - UsageNotifier

    func post(_ events: [ThresholdEvent], snapshot: UsageSnapshot) {
        let now = Date()
        let session = snapshot.session(at: now)
        let requests = events.map { Self.request(for: $0, session: session, now: now) }
        guard !requests.isEmpty else { return }
        let center = center
        Task {
            // Not authorized (or not asked yet): drop silently. Asking is the job of onboarding and Settings.
            guard Self.permission(of: await center.notificationSettings().authorizationStatus) == .allowed else {
                return
            }
            for request in requests {
                do {
                    try await center.add(request)
                } catch {
                    notificationLog.error(
                        "Could not post a notification: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Permission

    /// The permission as macOS currently has it; the user can change it in System Settings at any time.
    func permission() async -> NotificationPermission {
        Self.permission(of: await center.notificationSettings().authorizationStatus)
    }

    /// Shows the system permission prompt, but only when macOS has not asked yet (and never when
    /// ``allowsPermissionRequests`` is `false`). Returns the permission afterwards.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> NotificationPermission {
        let current = await permission()
        guard current == .notDetermined, allowsPermissionRequests else { return current }
        do {
            _ = try await center.requestAuthorization(options: [.alert])
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

    private static func permission(of status: UNAuthorizationStatus) -> NotificationPermission {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized, .provisional: .allowed
        case .denied: .denied
        @unknown default: .denied
        }
    }

    // MARK: - Content

    /// The notification for one event. `session` supplies the remaining share and the reset time.
    static func request(for event: ThresholdEvent, session: UsageLimit?, now: Date) -> UNNotificationRequest {
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
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
