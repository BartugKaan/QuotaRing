import Foundation
import QuotaRingCore
import Testing

/// The names `SettingsStore` saves under. They are spelled out here on purpose: they are what is on a user's disk, so
/// renaming one would silently reset (or, for consent, mis-read) a saved setting.
private enum Saved {
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
    static let customCLIPath = "customCLIPath"
    static let obsoleteSafetyStop = "cliRefreshDisabledForSafety"
}

/// What a launch like `QuotaRing -liveModeEnabled YES …` puts in front of every other saved value.
@MainActor
private func putOnTheCommandLine(_ values: [String: Any], in defaults: UserDefaults) {
    defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
}

@MainActor
@Suite struct SettingsStoreDefaultsTests {
    @Test func aFreshStoreHasTheDocumentedDefaults() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        let settings = sandbox.makeSettings()

        #expect(settings.refreshInterval == 300)
        #expect(settings.ringShowsRemaining)
        #expect(settings.showPercentText)
        #expect(settings.notificationThresholds == [80, 95])
        #expect(!settings.notifyOnReset)
        // Nothing that reads, runs or sends is on until the user says so.
        #expect(!settings.liveModeEnabled)
        #expect(!settings.hasCompletedOnboarding)
        #expect(!settings.cliRefreshEnabled)
        #expect(settings.cliRefreshSafetyStop == nil)
        #expect(settings.customCLIPath == nil)
        #expect(settings.customConfigDirectory == nil)
        #expect(!settings.isLiveModeActive)
        #expect(!settings.isCLIRefreshActive)
    }

    @Test func theOfferedIntervalsAreTheDocumentedOnes() {
        #expect(SettingsStore.refreshOptions == [180, 300, 600, 900])
        #expect(SettingsStore.refreshOptions.contains(SettingsStore.defaultRefreshInterval))
        #expect(SettingsStore.defaultNotificationThresholds == [80, 95])
    }

    @Test func creatingAStoreSavesNothing() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }

        _ = sandbox.makeSettings()

        // The properties' observers do not run in `init`, so merely launching writes no preference.
        #expect(sandbox.savedValues.isEmpty)
    }
}

@MainActor
@Suite struct SettingsStorePersistenceTests {
    @Test func everyValueIsSavedAndComesBackInANewStore() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let tool = try sandbox.write("bin/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)
        let config = try sandbox.folder("claude-config")

        let first = sandbox.makeSettings()
        first.refreshInterval = 600
        first.ringShowsRemaining = false
        first.showPercentText = false
        first.notificationThresholds = [50, 90]
        first.notifyOnReset = true
        first.liveModeEnabled = true
        first.hasCompletedOnboarding = true
        first.cliRefreshEnabled = true
        first.customCLIPath = tool
        first.customConfigDirectory = config

        let second = sandbox.makeSettings()
        #expect(second.refreshInterval == 600)
        #expect(!second.ringShowsRemaining)
        #expect(!second.showPercentText)
        #expect(second.notificationThresholds == [50, 90])
        #expect(second.notifyOnReset)
        #expect(second.liveModeEnabled)
        #expect(second.hasCompletedOnboarding)
        #expect(second.cliRefreshEnabled)
        #expect(second.customCLIPath?.path == tool.path)
        #expect(second.customConfigDirectory?.path == config.path)
        #expect(second.isLiveModeActive)
        #expect(second.isCLIRefreshActive)
    }

    @Test func valuesAreSavedUnderTheirDocumentedNames() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let config = try sandbox.folder("claude-config")

        let settings = sandbox.makeSettings()
        settings.refreshInterval = 900
        settings.liveModeEnabled = true
        settings.hasCompletedOnboarding = true
        settings.cliRefreshEnabled = true
        settings.customConfigDirectory = config
        settings.notificationThresholds = [70]

        let saved = sandbox.savedValues
        #expect(saved[Saved.refreshInterval] as? Double == 900)
        #expect(saved[Saved.liveModeEnabled] as? Bool == true)
        #expect(saved[Saved.hasCompletedOnboarding] as? Bool == true)
        #expect(saved[Saved.cliRefreshEnabled] as? Bool == true)
        #expect(saved[Saved.customConfigDirectory] as? String == config.path)
        #expect(saved[Saved.notificationThresholds] as? [Int] == [70])
    }

    @Test func liveModeAndAutoRefreshNeedACompletedOnboarding() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()

        settings.liveModeEnabled = true
        settings.cliRefreshEnabled = true
        #expect(!settings.isLiveModeActive)
        #expect(!settings.isCLIRefreshActive)

        settings.hasCompletedOnboarding = true
        #expect(settings.isLiveModeActive)
        #expect(settings.isCLIRefreshActive)

        settings.liveModeEnabled = false
        #expect(!settings.isLiveModeActive)
        #expect(settings.isCLIRefreshActive)
    }

    @Test func consentSavedBeforeOnboardingWasFinishedStaysInactiveAfterARelaunch() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set(true, forKey: Saved.liveModeEnabled)
        sandbox.defaults.set(true, forKey: Saved.cliRefreshEnabled)

        let settings = sandbox.makeSettings()

        #expect(settings.liveModeEnabled)
        #expect(settings.cliRefreshEnabled)
        #expect(!settings.isLiveModeActive)
        #expect(!settings.isCLIRefreshActive)
    }
}

@MainActor
@Suite struct SettingsStoreValidationTests {
    @Test(arguments: [0.0, 1, 179, 301, 3600, -300, .nan, .infinity])
    func anIntervalThatIsNotOfferedBecomesTheDefault(value: Double) throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()
        settings.refreshInterval = 900

        settings.refreshInterval = value

        #expect(settings.refreshInterval == 300)
        #expect(sandbox.savedValues[Saved.refreshInterval] as? Double == 300)
    }

    @Test(arguments: [180.0, 300, 600, 900])
    func everyOfferedIntervalIsAccepted(value: Double) throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()

        settings.refreshInterval = value

        #expect(settings.refreshInterval == value)
    }

    @Test func aHandEditedIntervalIsIgnoredWhenTheStoreStarts() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set(7.0, forKey: Saved.refreshInterval)

        #expect(sandbox.makeSettings().refreshInterval == 300)
    }

    @Test func thresholdsAreSortedUniqueAndInRange() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()

        settings.notificationThresholds = [95, 80, 80, 0, -5, 101, 1000, 100, 1]

        #expect(settings.notificationThresholds == [1, 80, 95, 100])
        #expect(sandbox.savedValues[Saved.notificationThresholds] as? [Int] == [1, 80, 95, 100])
    }

    @Test func noThresholdsIsAllowed() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()

        settings.notificationThresholds = []

        #expect(settings.notificationThresholds.isEmpty)
        // A saved empty list is "none", not "never set": the defaults do not come back.
        #expect(sandbox.makeSettings().notificationThresholds.isEmpty)
    }

    @Test func savedThresholdsAreCleanedWhenTheStoreStarts() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set([99, 0, 50, 50, 500], forKey: Saved.notificationThresholds)

        #expect(sandbox.makeSettings().notificationThresholds == [50, 99])
    }

    @Test func thresholdsOfTheWrongTypeFallBackToTheDefaults() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set(["eighty", "ninety-five"], forKey: Saved.notificationThresholds)

        #expect(sandbox.makeSettings().notificationThresholds == [80, 95])
    }

    @Test func displaySettingsOfTheWrongTypeFallBackToTheDefaults() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set("no", forKey: Saved.ringShowsRemaining)
        sandbox.defaults.set(["x"], forKey: Saved.showPercentText)
        sandbox.defaults.set("yes", forKey: Saved.notifyOnReset)

        let settings = sandbox.makeSettings()

        #expect(settings.ringShowsRemaining)
        #expect(settings.showPercentText)
        #expect(!settings.notifyOnReset)
    }
}

@MainActor
@Suite struct SettingsStoreConsentSourceTests {
    @Test func theCommandLineCannotTurnOnConsent() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let danger = try sandbox.write("elsewhere/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)
        putOnTheCommandLine(
            [
                Saved.liveModeEnabled: true,
                Saved.hasCompletedOnboarding: true,
                Saved.cliRefreshEnabled: true,
                Saved.customCLIPath: danger.path,
                Saved.customConfigDirectory: "/tmp/elsewhere",
                Saved.cliRefreshSafetyStop: "modelCall",
            ], in: sandbox.defaults)
        // The simulation works: an ordinary read does see the launch arguments, which is why the store must not.
        try #require(sandbox.defaults.bool(forKey: Saved.liveModeEnabled))

        let settings = sandbox.makeSettings()

        #expect(!settings.liveModeEnabled)
        #expect(!settings.hasCompletedOnboarding)
        #expect(!settings.cliRefreshEnabled)
        #expect(!settings.isLiveModeActive)
        #expect(!settings.isCLIRefreshActive)
        #expect(settings.customCLIPath == nil)
        #expect(settings.customConfigDirectory == nil)
        #expect(settings.cliRefreshSafetyStop == nil)
    }

    @Test func theCommandLineIsNotWrittenBackToTheSavedPreferences() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        putOnTheCommandLine(
            [
                Saved.liveModeEnabled: true, Saved.hasCompletedOnboarding: true, Saved.cliRefreshEnabled: true,
                Saved.customCLIPath: "/tmp/elsewhere/claude", Saved.customConfigDirectory: "/tmp/elsewhere",
            ], in: sandbox.defaults)

        _ = sandbox.makeSettings()

        // A relaunch without the arguments must find nothing of them.
        for key in [
            Saved.liveModeEnabled, Saved.hasCompletedOnboarding, Saved.cliRefreshEnabled, Saved.customCLIPath,
            Saved.customConfigDirectory,
        ] {
            #expect(sandbox.savedValues[key] == nil, "\(key) was saved")
        }
    }

    @Test func savedConsentIsKeptEvenWhenTheCommandLineSaysNo() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set(true, forKey: Saved.liveModeEnabled)
        sandbox.defaults.set(true, forKey: Saved.hasCompletedOnboarding)
        putOnTheCommandLine([Saved.liveModeEnabled: false], in: sandbox.defaults)

        let settings = sandbox.makeSettings()

        #expect(settings.liveModeEnabled)
        #expect(settings.isLiveModeActive)
    }

    @Test func displaySettingsMayComeFromTheCommandLine() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        putOnTheCommandLine(
            [Saved.ringShowsRemaining: false, Saved.showPercentText: false, Saved.refreshInterval: 600.0],
            in: sandbox.defaults)

        let settings = sandbox.makeSettings()

        #expect(!settings.ringShowsRemaining)
        #expect(!settings.showPercentText)
        #expect(settings.refreshInterval == 600)
    }

    @Test func withoutAPersistentDomainNoConsentIsRead() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set(true, forKey: Saved.liveModeEnabled)
        sandbox.defaults.set(true, forKey: Saved.hasCompletedOnboarding)
        sandbox.defaults.set(true, forKey: Saved.cliRefreshEnabled)
        sandbox.defaults.set("/usr/bin/claude", forKey: Saved.customCLIPath)

        let settings = SettingsStore(defaults: sandbox.defaults, persistentDomain: nil)

        #expect(!settings.liveModeEnabled)
        #expect(!settings.hasCompletedOnboarding)
        #expect(!settings.cliRefreshEnabled)
        #expect(settings.customCLIPath == nil)
    }

    @Test func aRelativeSavedPathIsNeverUsed() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set("bin/claude", forKey: Saved.customCLIPath)
        sandbox.defaults.set("claude-config", forKey: Saved.customConfigDirectory)

        let settings = sandbox.makeSettings()

        #expect(settings.customCLIPath == nil)
        #expect(settings.customConfigDirectory == nil)
    }
}

@MainActor
@Suite struct SettingsStoreObsoleteKeyTests {
    @Test func theObsoleteSafetyStopKeyIsDeletedAndNeverRead() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set(true, forKey: Saved.obsoleteSafetyStop)
        sandbox.defaults.set(true, forKey: Saved.hasCompletedOnboarding)
        try #require(sandbox.savedValues[Saved.obsoleteSafetyStop] != nil)

        let settings = sandbox.makeSettings()

        #expect(sandbox.savedValues[Saved.obsoleteSafetyStop] == nil)
        // It was not migrated into the current key either.
        #expect(settings.cliRefreshSafetyStop == nil)
        #expect(sandbox.savedValues[Saved.cliRefreshSafetyStop] == nil)
        #expect(!settings.cliRefreshEnabled)
        // Unrelated saved values stay.
        #expect(sandbox.savedValues[Saved.hasCompletedOnboarding] as? Bool == true)
    }

    @Test func deletingTheObsoleteKeyWorksWhenItIsOnlyOnTheCommandLine() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        putOnTheCommandLine([Saved.obsoleteSafetyStop: true], in: sandbox.defaults)

        let settings = sandbox.makeSettings()

        #expect(settings.cliRefreshSafetyStop == nil)
        #expect(!settings.cliRefreshEnabled)
    }
}

@MainActor
@Suite struct SettingsStoreSafetyStopTests {
    @Test(arguments: CLISafetyStop.allCases)
    func aSafetyStopTurnsAutoRefreshOffAndIsRemembered(reason: CLISafetyStop) throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()
        settings.hasCompletedOnboarding = true
        settings.cliRefreshEnabled = true

        settings.stopCLIRefreshForSafety(reason)

        #expect(!settings.cliRefreshEnabled)
        #expect(!settings.isCLIRefreshActive)
        #expect(settings.cliRefreshSafetyStop == reason)
        #expect(sandbox.savedValues[Saved.cliRefreshSafetyStop] as? String == reason.rawValue)

        // Also after a relaunch, so the app can still say why it is off.
        let relaunched = sandbox.makeSettings()
        #expect(relaunched.cliRefreshSafetyStop == reason)
        #expect(!relaunched.cliRefreshEnabled)
    }

    @Test func turningAutoRefreshBackOnClearsTheStop() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()
        settings.stopCLIRefreshForSafety(.modelCall)
        try #require(settings.cliRefreshSafetyStop == .modelCall)

        settings.cliRefreshEnabled = true

        #expect(settings.cliRefreshSafetyStop == nil)
        #expect(sandbox.savedValues[Saved.cliRefreshSafetyStop] == nil)
        #expect(sandbox.makeSettings().cliRefreshSafetyStop == nil)
    }

    @Test func switchingAutoRefreshOffByHandKeepsNoStop() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()
        settings.cliRefreshEnabled = true

        settings.cliRefreshEnabled = false

        #expect(settings.cliRefreshSafetyStop == nil)
    }

    @Test func anUnknownSavedStopReasonIsIgnored() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        sandbox.defaults.set("someFutureReason", forKey: Saved.cliRefreshSafetyStop)

        #expect(sandbox.makeSettings().cliRefreshSafetyStop == nil)
    }
}

@MainActor
@Suite struct SettingsStoreToolPathTests {
    @Test func aValidToolIsAcceptedAndSaved() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let tool = try sandbox.write("bin/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)
        let settings = sandbox.makeSettings()

        settings.customCLIPath = tool

        #expect(settings.customCLIPath?.path == tool.path)
        #expect(sandbox.savedValues[Saved.customCLIPath] as? String == tool.path)
    }

    @Test func removingTheChoiceForgetsIt() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let tool = try sandbox.write("bin/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)
        let settings = sandbox.makeSettings()
        settings.customCLIPath = tool

        settings.customCLIPath = nil

        #expect(settings.customCLIPath == nil)
        #expect(sandbox.savedValues[Saved.customCLIPath] == nil)
    }

    @Test func aFileThatIsNotAcceptableLeavesTheChoiceUnchanged() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let good = try sandbox.write("bin/claude", "#!/bin/sh\nexit 0\n", mode: 0o755)
        let settings = sandbox.makeSettings()
        settings.customCLIPath = good

        let missing = sandbox.directory.appendingPathComponent("nowhere/claude")
        let notExecutable = try sandbox.write("plain/claude", "text", mode: 0o644)
        let writableByOthers = try sandbox.write("loose/claude", "#!/bin/sh\n", mode: 0o777)
        let folder = try sandbox.folder("folder")
        let notAFileURL = try #require(URL(string: "https://example.invalid/claude"))
        for rejected in [missing, notExecutable, writableByOthers, folder, notAFileURL] {
            settings.customCLIPath = rejected
            #expect(settings.customCLIPath?.path == good.path, "accepted \(rejected)")
        }
        #expect(sandbox.savedValues[Saved.customCLIPath] as? String == good.path)
    }

    @Test func aRejectedFirstChoiceLeavesItUnset() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let settings = sandbox.makeSettings()

        settings.customCLIPath = sandbox.directory.appendingPathComponent("nowhere/claude")

        #expect(settings.customCLIPath == nil)
        #expect(sandbox.savedValues[Saved.customCLIPath] == nil)
    }
}

@MainActor
@Suite struct SettingsStoreConfigDirectoryTests {
    @Test func aChosenDirectoryIsSavedAndRemoved() throws {
        let sandbox = try TestSandbox()
        defer { sandbox.remove() }
        let config = try sandbox.folder("other-claude")
        let settings = sandbox.makeSettings()

        settings.customConfigDirectory = config
        #expect(settings.customConfigDirectory?.path == config.path)
        #expect(settings.customConfigDirectory?.hasDirectoryPath == true)
        #expect(sandbox.savedValues[Saved.customConfigDirectory] as? String == config.path)

        settings.customConfigDirectory = nil
        #expect(settings.customConfigDirectory == nil)
        #expect(sandbox.savedValues[Saved.customConfigDirectory] == nil)
    }
}
