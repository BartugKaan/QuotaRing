import Foundation
import Observation

/// The user's preferences, backed by `UserDefaults`.
///
/// Holds non-sensitive values only: no token, no file contents, no usage data. Values read back from
/// `UserDefaults` are validated, so a hand-edited or outdated plist cannot put the app in an unsupported state.
@MainActor @Observable
final class SettingsStore {
    /// The refresh intervals offered in Settings, in seconds.
    static let refreshOptions: [TimeInterval] = [180, 300, 600, 900]

    static let defaultRefreshInterval: TimeInterval = 300
    static let defaultNotificationThresholds = [80, 95]

    /// Seconds between automatic Live requests; one of ``refreshOptions``.
    var refreshInterval: TimeInterval {
        didSet {
            if !Self.refreshOptions.contains(refreshInterval) {
                refreshInterval = Self.defaultRefreshInterval
            }
            defaults.set(refreshInterval, forKey: Key.refreshInterval)
        }
    }

    /// Whether the ring shows the share still available (`true`) or the share already used.
    var ringShowsRemaining: Bool {
        didSet { defaults.set(ringShowsRemaining, forKey: Key.ringShowsRemaining) }
    }

    /// Whether the menu bar shows the percentage next to the ring.
    var showPercentText: Bool {
        didSet { defaults.set(showPercentText, forKey: Key.showPercentText) }
    }

    /// Percent-used values that trigger a notification, ascending, each in `1...100`.
    var notificationThresholds: [Int] {
        didSet {
            let sanitized = Self.sanitize(notificationThresholds)
            if sanitized != notificationThresholds {
                notificationThresholds = sanitized
            }
            defaults.set(notificationThresholds, forKey: Key.notificationThresholds)
        }
    }

    /// Whether to notify when a new session window starts.
    var notifyOnReset: Bool {
        didSet { defaults.set(notifyOnReset, forKey: Key.notifyOnReset) }
    }

    /// The user's consent to Live mode (Keychain read plus a request to `api.anthropic.com`). Off by default.
    var liveModeEnabled: Bool {
        didSet { defaults.set(liveModeEnabled, forKey: Key.liveModeEnabled) }
    }

    /// Whether the first-run onboarding was completed. Live mode never runs before it.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// A Claude config directory chosen in Settings, or `nil` for the default `~/.claude`.
    var customConfigDirectory: URL? {
        get { customConfigPath.isEmpty ? nil : URL(fileURLWithPath: customConfigPath, isDirectory: true) }
        set { customConfigPath = newValue?.path ?? "" }
    }

    /// Backing store of ``customConfigDirectory``; empty for the default. Deliberately not optional: `@Observable`
    /// pre-initializes optional properties to `nil`, so assigning one in `init` would run its `didSet` and write
    /// launch-argument overrides back to the persistent defaults.
    private var customConfigPath: String {
        didSet {
            if customConfigPath.isEmpty {
                defaults.removeObject(forKey: Key.customConfigDirectory)
            } else {
                defaults.set(customConfigPath, forKey: Key.customConfigDirectory)
            }
        }
    }

    /// Whether Live requests may be made: consent was given and onboarding is done.
    var isLiveModeActive: Bool {
        liveModeEnabled && hasCompletedOnboarding
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedInterval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval =
            Self.refreshOptions.contains(storedInterval) ? storedInterval : Self.defaultRefreshInterval
        ringShowsRemaining = defaults.object(forKey: Key.ringShowsRemaining) as? Bool ?? true
        showPercentText = defaults.object(forKey: Key.showPercentText) as? Bool ?? true
        if let stored = defaults.array(forKey: Key.notificationThresholds) as? [Int] {
            notificationThresholds = Self.sanitize(stored)
        } else {
            notificationThresholds = Self.defaultNotificationThresholds
        }
        notifyOnReset = defaults.object(forKey: Key.notifyOnReset) as? Bool ?? false
        liveModeEnabled = defaults.object(forKey: Key.liveModeEnabled) as? Bool ?? false
        hasCompletedOnboarding = defaults.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        if let path = defaults.string(forKey: Key.customConfigDirectory), path.hasPrefix("/") {
            customConfigPath = path
        } else {
            customConfigPath = ""
        }
    }

    private static func sanitize(_ thresholds: [Int]) -> [Int] {
        Set(thresholds.filter { (1...100).contains($0) }).sorted()
    }

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let ringShowsRemaining = "ringShowsRemaining"
        static let showPercentText = "showPercentText"
        static let notificationThresholds = "notificationThresholds"
        static let notifyOnReset = "notifyOnReset"
        static let liveModeEnabled = "liveModeEnabled"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let customConfigDirectory = "customConfigDirectory"
    }
}
