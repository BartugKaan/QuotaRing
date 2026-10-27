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
    ///
    /// It counts only when it was given for the current ``UsageAPI/consentVersion``: a consent saved by a build whose
    /// Live mode did something else (or by one that saved no version) reads as `false`, so the user is asked again.
    /// Setting it to `true` records the consent for the current version, which only onboarding and the consent sheet
    /// do; setting it to `false` clears the version too.
    var liveModeEnabled: Bool {
        get { liveModeConsent && liveModeConsentVersion == UsageAPI.consentVersion }
        set {
            liveModeConsent = newValue
            liveModeConsentVersion = newValue ? UsageAPI.consentVersion : 0
        }
    }

    /// Backing store of ``liveModeEnabled``: the saved answer, whatever version it was given for.
    private var liveModeConsent: Bool {
        didSet { defaults.set(liveModeConsent, forKey: Key.liveModeEnabled) }
    }

    /// The ``UsageAPI/consentVersion`` the Live mode consent was given for; 0 for none. Read only from the app's saved
    /// preferences, like the consent itself. Not optional, for the same reason as `customConfigPath`.
    private(set) var liveModeConsentVersion: Int {
        didSet { Self.save(version: liveModeConsentVersion, forKey: Key.liveModeConsentVersion, in: defaults) }
    }

    /// Whether the first-run onboarding was completed. Live mode never runs before it. Read only from the app's saved
    /// preferences, never from launch arguments.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    /// The user's consent to refresh through Claude Code ("auto-refresh"): running `claude -p "/usage" …` in the
    /// background (see ``CLIRefreshCommand``). Off unless chosen in onboarding or Settings. Read only from the app's
    /// saved preferences, never from launch arguments. Turning it on clears ``cliRefreshSafetyStop``.
    ///
    /// It counts only when it was given for the current ``CLIRefreshCommand/consentVersion``: a consent saved by a build
    /// that ran another command or environment (or by one that saved no version) reads as `false`, so the user is
    /// asked again. Setting it to `true` records the consent for the current version, which only onboarding and the
    /// consent sheet do; setting it to `false` (also a safety stop) clears the version too.
    var cliRefreshEnabled: Bool {
        get { cliRefreshConsent && cliRefreshConsentVersion == CLIRefreshCommand.consentVersion }
        set {
            cliRefreshConsent = newValue
            cliRefreshConsentVersion = newValue ? CLIRefreshCommand.consentVersion : 0
            if newValue, cliRefreshSafetyStop != nil {
                cliRefreshSafetyStop = nil
            }
        }
    }

    /// Whether auto-refresh is off only because the user agreed to it for another ``CLIRefreshCommand/consentVersion``:
    /// an update changed what it runs. The app says so until the user turns it on (agreeing to the new version) or off.
    var cliRefreshNeedsNewConsent: Bool {
        cliRefreshConsent && cliRefreshConsentVersion != CLIRefreshCommand.consentVersion
    }

    /// Backing store of ``cliRefreshEnabled``: the saved answer, whatever version it was given for.
    private var cliRefreshConsent: Bool {
        didSet { defaults.set(cliRefreshConsent, forKey: Key.cliRefreshEnabled) }
    }

    /// The ``CLIRefreshCommand/consentVersion`` the auto-refresh consent was given for; 0 for none. Read only from the
    /// app's saved preferences, like the consent itself. Not optional, for the same reason as `customConfigPath`.
    private(set) var cliRefreshConsentVersion: Int {
        didSet { Self.save(version: cliRefreshConsentVersion, forKey: Key.cliRefreshConsentVersion, in: defaults) }
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

    /// A Claude config directory chosen in Settings, or `nil` for the default `~/.claude`. Read only from the app's saved
    /// preferences, never from launch arguments: auto-refresh passes it to Claude Code as `CLAUDE_CONFIG_DIR`.
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
        // Keychain reads without the user ever agreeing. (Display settings may still come from there.)
        let saved = persistentDomain.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        liveModeConsent = saved[Key.liveModeEnabled] as? Bool ?? false
        liveModeConsentVersion = Self.version(saved[Key.liveModeConsentVersion])
        hasCompletedOnboarding = saved[Key.hasCompletedOnboarding] as? Bool ?? false
        // Running a program is consent too, and which program runs must not come from the command line either.
        cliRefreshConsent = saved[Key.cliRefreshEnabled] as? Bool ?? false
        cliRefreshConsentVersion = Self.version(saved[Key.cliRefreshConsentVersion])
        if let stop = (saved[Key.cliRefreshSafetyStop] as? String).flatMap(CLISafetyStop.init(rawValue:)) {
            cliSafetyStopValue = stop.rawValue
        } else {
            cliSafetyStopValue = ""
        }
        // A key of unreleased development builds, superseded by `cliRefreshSafetyStop`: removed, never read.
        defaults.removeObject(forKey: Key.obsoleteCLIRefreshDisabledForSafety)
        if let path = saved[Key.customCLIPath] as? String, path.hasPrefix("/") {
            customCLIPathValue = path
        } else {
            customCLIPathValue = ""
        }
        // Where Claude Code's data is decides what an executed program is pointed at (CLAUDE_CONFIG_DIR), so it must not
        // come from the command line either.
        if let path = saved[Key.customConfigDirectory] as? String, path.hasPrefix("/") {
            customConfigPath = path
        } else {
            customConfigPath = ""
        }
    }

    private static func sanitize(_ thresholds: [Int]) -> [Int] {
        Set(thresholds.filter { (1...100).contains($0) }).sorted()
    }

    /// A saved consent version: a positive whole number, else 0 (none). A Boolean is not a version, even though
    /// property lists bridge it to a number.
    private static func version(_ value: Any?) -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let version = Int(exactly: number.doubleValue), version > 0
        else { return 0 }
        return version
    }

    private static func save(version: Int, forKey key: String, in defaults: UserDefaults) {
        if version > 0 {
            defaults.set(version, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let ringShowsRemaining = "ringShowsRemaining"
        static let showPercentText = "showPercentText"
        static let notificationThresholds = "notificationThresholds"
        static let notifyOnReset = "notifyOnReset"
        static let liveModeEnabled = "liveModeEnabled"
        static let liveModeConsentVersion = "liveModeConsentVersion"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let customConfigDirectory = "customConfigDirectory"
        static let cliRefreshEnabled = "cliRefreshEnabled"
        static let cliRefreshConsentVersion = "cliRefreshConsentVersion"
        static let cliRefreshSafetyStop = "cliRefreshSafetyStop"
        static let obsoleteCLIRefreshDisabledForSafety = "cliRefreshDisabledForSafety"
        static let customCLIPath = "customCLIPath"
    }
}
