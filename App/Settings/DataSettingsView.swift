import AppKit
import QuotaRingCore
import SwiftUI

/// Where the numbers come from: the files QuotaRing reads, the Claude config directory, auto-refresh through Claude
/// Code, and the Live mode switch.
struct DataSettingsView: View {
    @Bindable var settings: SettingsStore
    /// Auto-refresh's status and the tool it found.
    let model: AppModel
    @State private var showsLiveModeConsent = false
    @State private var showsCLIRefreshConsent = false
    /// Why the file just chosen as Claude Code's tool was refused.
    @State private var cliChoiceProblem: CLIValidationError?

    /// Demo mode runs on fixture data: the sources, auto-refresh and Live mode cannot be changed.
    private var isDemo: Bool { model.isDemo }

    private var paths: ClaudePaths {
        ClaudePaths(customConfigDirectory: settings.customConfigDirectory)
    }

    var body: some View {
        Form {
            sourcesSection
            directorySection
            cliRefreshSection
            liveModeSection
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        // The Settings window is as tall as this content, so on a short screen (or with longer translations) it
        // scrolls instead of growing past the visible screen. Chrome: the window's title bar and toolbar.
        .scrollsBeyond(VisibleScreen.contentHeight(reserving: 88))
        .sheet(isPresented: $showsLiveModeConsent) {
            LiveModeConsentSheet(
                onEnable: {
                    settings.liveModeEnabled = true
                    showsLiveModeConsent = false
                },
                onCancel: { showsLiveModeConsent = false })
        }
        .sheet(isPresented: $showsCLIRefreshConsent) {
            CLIRefreshConsentSheet(
                refreshInterval: settings.refreshInterval,
                toolPath: foundTool.map { Self.displayPath($0.path) },
                onEnable: {
                    settings.cliRefreshEnabled = true
                    showsCLIRefreshConsent = false
                },
                onCancel: { showsCLIRefreshConsent = false })
        }
        // The user may have installed or moved Claude Code since; looking only reads file metadata.
        .onAppear { model.inspectCLI() }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section {
            SourceRow(
                symbol: "doc.text",
                title: "Usage cache",
                text: "The usage numbers Claude Code already saves for itself. QuotaRing never writes to the file.",
                path: Self.displayPath(paths.globalConfigFile))
            SourceRow(
                symbol: "text.alignleft",
                title: "Transcripts",
                text: "Token counts per model, project and day. The text of your conversations is not kept.",
                path: Self.displayPath(paths.projectsDirectory))
        } header: {
            Text("Where QuotaRing gets its numbers")
        } footer: {
            Text("These two are read on this Mac only; they are never sent anywhere.")
        }
    }

    // MARK: - Claude config directory

    private var directorySection: some View {
        Section {
            HStack {
                let directory = Self.displayPath(paths.configDirectory)
                Text(directory)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(paths.configDirectory.path)
                    .accessibilityLabel(
                        String(
                            localized: "Claude config directory: \(directory)",
                            comment: "VoiceOver label of the folder path; the argument is a path such as ~/.claude"))
                Spacer(minLength: 8)
                Button("Choose…") { Task { await chooseDirectory() } }
                Button("Reset to default") { settings.customConfigDirectory = nil }
                    .disabled(settings.customConfigDirectory == nil)
            }
            .disabled(isDemo)
        } header: {
            Text("Claude config directory")
        } footer: {
            Text(directoryFooter)
        }
    }

    private var directoryFooter: LocalizedStringKey {
        if isDemo {
            "Demo mode shows sample data and reads no files."
        } else {
            "Only needed if you run Claude Code with a custom config directory (CLAUDE_CONFIG_DIR)."
        }
    }

    @MainActor
    private func chooseDirectory() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        // The default folder, ~/.claude, is hidden.
        panel.showsHiddenFiles = true
        panel.prompt = String(localized: "Choose", comment: "Folder picker confirm button")
        panel.message = String(
            localized: "Choose the folder Claude Code keeps its data in. The default is ~/.claude.",
            comment: "Folder picker message")
        panel.directoryURL = paths.configDirectory
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return }
        settings.customConfigDirectory = Self.customDirectory(from: url)
    }

    /// The directory to store for a chosen folder: `nil` when it is the default `~/.claude`, which is what "default"
    /// means everywhere else (for example, the Keychain item names differ for a custom directory).
    static func customDirectory(
        from chosen: URL,
        defaultDirectory: URL = ClaudePaths().configDirectory
    ) -> URL? {
        let standardized = ClaudePaths(customConfigDirectory: chosen).configDirectory
        if standardized.path == defaultDirectory.path
            || standardized.resolvingSymlinksInPath().path == defaultDirectory.resolvingSymlinksInPath().path
        {
            return nil
        }
        return standardized
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Auto-refresh through Claude Code

    private var foundTool: CLIExecutable? {
        model.cliBinary?.location.executable
    }

    private var cliRefreshSection: some View {
        Section {
            Toggle("Refresh with Claude Code", isOn: cliRefreshBinding)
                .disabled(isDemo || !settings.hasCompletedOnboarding)
                .accessibilityHint(
                    Text("The text below explains what auto-refresh runs and how often."))
            CLIRefreshDisclosure(compact: true, refreshInterval: settings.refreshInterval)
            cliToolRow
            if CLIRefreshText.statusMessage(model.cliStatus, now: .now) != nil {
                // Ticks so that "last ran 3 min ago" stays true while the window is open.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    cliStatusLabel(now: context.date)
                }
            }
        } footer: {
            Text(cliRefreshFooter)
        }
    }

    @ViewBuilder
    private func cliStatusLabel(now: Date) -> some View {
        if let message = CLIRefreshText.statusMessage(model.cliStatus, now: now) {
            let attention = model.cliStatus.needsAttention
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: attention ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(attention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .font(.callout)
        }
    }

    /// Where Claude Code's tool is, its version, and the buttons to choose another one or go back to looking for it.
    private var cliToolRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Command-line tool")
                        .fontWeight(.semibold)
                    if let tool = foundTool {
                        let path = Self.displayPath(tool.path)
                        Text(verbatim: path)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(tool.executable.path)
                        Text(versionText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(toolMissingText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
                Button("Choose…") { Task { await chooseCLI() } }
                Button("Reset") {
                    cliChoiceProblem = nil
                    settings.customCLIPath = nil
                }
                .disabled(settings.customCLIPath == nil)
            }
            if let problem = cliChoiceProblem ?? model.cliBinary?.location.customPathProblem {
                Label {
                    Text(CLIRefreshText.validationMessage(problem))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                .font(.callout)
            }
        }
        .disabled(isDemo)
    }

    private var toolMissingText: LocalizedStringKey {
        if isDemo {
            "Not looked for in demo mode"
        } else if model.cliBinary == nil {
            "Looking…"
        } else {
            "Not found"
        }
    }

    private var versionText: LocalizedStringKey {
        switch model.cliBinary?.versionCheck {
        case .claudeCode(let version?):
            "Claude Code \(version)"
        case .claudeCode(nil):
            "Claude Code"
        case .notClaudeCode:
            "This file is not Claude Code, so it is never run with `/usage`."
        case nil:
            "The version is checked before the first run."
        }
    }

    private var cliRefreshBinding: Binding<Bool> {
        Binding(
            get: { settings.cliRefreshEnabled },
            set: { enabled in
                if enabled {
                    // Never switched on directly: the consent sheet does it when the user agrees.
                    showsCLIRefreshConsent = true
                } else {
                    settings.cliRefreshEnabled = false
                }
            }
        )
    }

    private var cliRefreshFooter: LocalizedStringKey {
        if isDemo {
            "Demo mode shows sample data: auto-refresh cannot be changed."
        } else if !settings.hasCompletedOnboarding {
            "Finish the welcome window first."
        } else if settings.cliRefreshEnabled {
            "Auto-refresh is on. Turning it off stops it right away."
        } else {
            "Auto-refresh is off. QuotaRing does not run Claude Code."
        }
    }

    @MainActor
    private func chooseCLI() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        // ~/.local and ~/.npm-global are hidden; and a link such as ~/.local/bin/claude is kept as it is, so that it
        // keeps working when Claude Code updates itself and points it to a new version.
        panel.showsHiddenFiles = true
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = String(localized: "Choose", comment: "Folder picker confirm button")
        panel.message = String(
            localized:
                "Choose Claude Code's command-line tool, claude. It is often in ~/.local/bin, ~/.npm-global/bin, /opt/homebrew/bin or /usr/local/bin.",
            comment: "File picker message for Claude Code's command-line tool")
        panel.directoryURL = foundTool?.path.deletingLastPathComponent()
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }
        guard response == .OK, let url = panel.url else { return }
        switch ClaudeCLILocator.validate(url) {
        case .success:
            cliChoiceProblem = nil
            settings.customCLIPath = url
        case .failure(let problem):
            cliChoiceProblem = problem
        }
    }

    // MARK: - Live mode

    private var liveModeSection: some View {
        Section {
            Toggle("Live mode", isOn: liveModeBinding)
                .disabled(isDemo || !settings.hasCompletedOnboarding)
                .accessibilityHint(
                    Text("The text below explains what Live mode reads and where it sends it."))
            LiveModeDisclosure(compact: true)
        } footer: {
            Text(liveModeFooter)
        }
    }

    private var liveModeBinding: Binding<Bool> {
        Binding(
            get: { settings.liveModeEnabled },
            set: { enabled in
                if enabled {
                    // Never switched on directly: the consent sheet does it when the user agrees.
                    showsLiveModeConsent = true
                } else {
                    settings.liveModeEnabled = false
                }
            }
        )
    }

    private var liveModeFooter: LocalizedStringKey {
        if isDemo {
            "Demo mode shows sample data: Live mode cannot be changed."
        } else if !settings.hasCompletedOnboarding {
            "Finish the welcome window first."
        } else if settings.liveModeEnabled {
            "Live mode is on. Turning it off stops all Keychain reads and network requests right away."
        } else {
            "Live mode is off. Nothing is read from the Keychain and QuotaRing makes no network requests."
        }
    }
}

/// A file or folder QuotaRing reads, with what it takes from it.
private struct SourceRow: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    let path: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Text(path)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
