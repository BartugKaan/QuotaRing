import Foundation
import Observation
import QuotaRingCore

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

    /// The user's consent to Live mode (Keychain read plus a request to `api.anthropic.com`). Off by default. Read only
    /// from the app's saved preferences, never from launch arguments.
    var liveModeEnabled: Bool {
        didSet { defaults.set(liveModeEnabled, forKey: Key.liveModeEnabled) }
    }

    /// Whether the first-run onboarding was completed. Live mode never runs before it. Read only from the app's saved
    /// preferences, never from launch arguments.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// The user's consent to refresh through Claude Code ("auto-refresh"): running `claude -p "/usage" …` in the
    /// background (see ``CLIRefreshCommand``). Off unless chosen in onboarding or Settings. Read only from the app's
    /// saved preferences, never from launch arguments. Turning it on clears ``cliRefreshSafetyStop``.
    var cliRefreshEnabled: Bool {
        didSet {
            defaults.set(cliRefreshEnabled, forKey: Key.cliRefreshEnabled)
            if cliRefreshEnabled, cliRefreshSafetyStop != nil {
                cliRefreshSafetyStop = nil
            }
        }
    }

    /// Why auto-refresh turned itself off (see ``CLISafetyStop``), so the app can say so, also after a relaunch; `nil`
    /// when it did not.
    private(set) var cliRefreshSafetyStop: CLISafetyStop? {
        get { CLISafetyStop(rawValue: cliSafetyStopValue) }
        set { cliSafetyStopValue = newValue?.rawValue ?? "" }
    }

    /// Backing store of ``cliRefreshSafetyStop``; empty for none. Not optional, for the same reason as
    /// `customConfigPath`.
    private var cliSafetyStopValue: String {
        didSet {
            if cliSafetyStopValue.isEmpty {
                defaults.removeObject(forKey: Key.cliRefreshSafetyStop)
            } else {
                defaults.set(cliSafetyStopValue, forKey: Key.cliRefreshSafetyStop)
            }
        }
    }

    /// The `claude` tool chosen in Settings, or `nil` to look in the standard places. Only a file that passes
    /// ``ClaudeCLILocator/validate(_:)`` is accepted; anything else leaves the value unchanged. Read only from the app's
    /// saved preferences, never from launch arguments, because it decides which program QuotaRing runs.
    var customCLIPath: URL? {
        get { customCLIPathValue.isEmpty ? nil : URL(fileURLWithPath: customCLIPathValue, isDirectory: false) }
        set {
            guard let newValue else {
                customCLIPathValue = ""
                return
            }
            guard newValue.isFileURL, case .success = ClaudeCLILocator.validate(newValue) else { return }
            customCLIPathValue = newValue.path
        }
    }

    /// Backing store of ``customCLIPath``; empty for none. Not optional, for the same reason as `customConfigPath`.
    private var customCLIPathValue: String {
        didSet {
            if customCLIPathValue.isEmpty {
                defaults.removeObject(forKey: Key.customCLIPath)
            } else {
                defaults.set(customCLIPathValue, forKey: Key.customCLIPath)
            }
        }
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

    /// Whether Claude Code may be run to refresh its cache: consent was given and onboarding is done.
    var isCLIRefreshActive: Bool {
        cliRefreshEnabled && hasCompletedOnboarding
    }

    /// Turns auto-refresh off for `reason` and remembers it until the user turns auto-refresh on again.
    func stopCLIRefreshForSafety(_ reason: CLISafetyStop) {
        cliRefreshEnabled = false
        cliRefreshSafetyStop = reason
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameters:
    ///   - defaults: Where preferences are read and written.
    ///   - persistentDomain: The name of the domain `defaults` saves to: the bundle identifier for `.standard`, the
    ///     suite name for a suite. The consent settings are read from this domain only (see below); `nil` leaves them
    ///     off.
    init(defaults: UserDefaults = .standard, persistentDomain: String? = Bundle.main.bundleIdentifier) {
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
        // Consent is read from what the app itself saved, never from launch arguments: `UserDefaults` also answers from
        // the argument domain, so `-liveModeEnabled YES -hasCompletedOnboarding YES` on the command line would turn on
        // Keychain reads without the user ever agreeing. (Display settings and the development-only
        // `-customConfigDirectory` override may still come from there.)
        let saved = persistentDomain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        liveModeEnabled = saved[Key.liveModeEnabled] as? Bool ?? false
        hasCompletedOnboarding = saved[Key.hasCompletedOnboarding] as? Bool ?? false
        // Running a program is consent too, and which program runs must not come from the command line either.
        cliRefreshEnabled = saved[Key.cliRefreshEnabled] as? Bool ?? false
        if let stop = (saved[Key.cliRefreshSafetyStop] as? String).flatMap(CLISafetyStop.init(rawValue:)) {
            cliSafetyStopValue = stop.rawValue
        } else if saved[Key.legacyCLIRefreshDisabledForSafety] as? Bool == true {
            // Development builds before the reason was kept only knew one: a model request.
            cliSafetyStopValue = CLISafetyStop.modelCall.rawValue
        } else {
            cliSafetyStopValue = ""
        }
        if let path = saved[Key.customCLIPath] as? String, path.hasPrefix("/") {
            customCLIPathValue = path
        } else {
            customCLIPathValue = ""
        }
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
        static let cliRefreshEnabled = "cliRefreshEnabled"
        static let cliRefreshSafetyStop = "cliRefreshSafetyStop"
        static let legacyCLIRefreshDisabledForSafety = "cliRefreshDisabledForSafety"
        static let customCLIPath = "customCLIPath"
    }
}
