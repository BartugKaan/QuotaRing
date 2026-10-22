# Contributing to QuotaRing

Thanks for your interest in QuotaRing. The project's value is that it is small, readable and trustworthy, so
contributions are judged by that standard as much as by whether they work.

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Contributions are licensed under the
[MIT License](LICENSE).

**Security issues:** do not open a public issue or pull request. Follow [SECURITY.md](SECURITY.md).

## Ground rules

These are non-negotiable, because they are what users trust the app for:

- The only network host is `api.anthropic.com`. No telemetry, analytics, crash reporting or update pings.
- Never write, refresh, persist, log or print an OAuth token. Never write to `~/.claude.json`, anything under
  `~/.claude/`, or Keychain items. Never launch the `claude` CLI.
- No third-party runtime dependencies. Apple's SDKs only.
- Percentages from Anthropic are **percent used** (0 to 100). Remaining is `100 - used`.
- Keep it auditable: prefer small, plain code over clever abstractions.

If you are unsure whether an idea fits, open a feature request first and describe what it would read, send or store.

## Prerequisites

- macOS 14 or later
- Xcode 16.4 or later (Swift 6 language mode, strict concurrency). CI tests with Xcode 16.4 and with the newest Xcode.
- [Homebrew](https://brew.sh)

Then, from the repository root:

```sh
make setup   # installs XcodeGen via the Brewfile
make run     # generates the project, builds and launches the app
```

The Xcode project is generated from `project.yml` and is git-ignored. Never commit `*.xcodeproj`.

## Make targets

| Target | What it does |
| --- | --- |
| `make setup` | Installs dev tools (XcodeGen) with Homebrew, using the [`Brewfile`](Brewfile) |
| `make generate` | Generates `QuotaRing.xcodeproj` from `project.yml` |
| `make build` | Generates the project and builds the `QuotaRing` scheme (Debug) |
| `make run` | Builds and launches the app |
| `make demo` | Launches the app with fixture data: no Keychain, no network, no Claude files |
| `make test` | Runs Core's tests: `swift test --package-path Core` (works without Xcode project generation) |
| `make test-app` | Generates the project and runs the app's unit tests (`QuotaRingAppTests`, unsigned, no app launch) |
| `make test-all` | Runs `make test` and `make test-app` |
| `make lint` | Runs `swift format lint` with the repository's `.swift-format` on `Core`, `App` and `AppTests` |
| `make format` | Formats the code in place with `swift format` |
| `make clean` | Removes build products |

The [`Makefile`](Makefile) is the source of truth if this table ever drifts.

CI builds with `make build XCODEBUILD_FLAGS="CODE_SIGNING_ALLOWED=NO"`. You can pass the same variable locally. CI
installs a pinned XcodeGen release with a verified checksum (`scripts/ci/install-xcodegen.sh`); `make setup` installs
whichever version Homebrew has.

### Signing for local builds

The project builds ad-hoc signed ("Sign to Run Locally"), so you need no developer account. If you want a stable
signature (for example to keep a Keychain "Always Allow" grant across rebuilds while testing Live mode), copy
[`Configs/Local.xcconfig.example`](Configs/Local.xcconfig.example) to `Configs/Local.xcconfig` and set your team there.
That file is git-ignored. Never commit team IDs, certificates, keys or tokens.

## Where things live

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). In short: logic that does not need a UI lives in the `Core` Swift
package (`QuotaRingCore`) and is tested with `swift test`. The AppKit and SwiftUI shell lives in `App`.

## Workflow

1. Fork the repository and create a branch from `main`. Use a descriptive prefix: `feat/...`, `fix/...`, `docs/...`,
   `refactor/...`, `test/...`, `ci/...`.
2. Make focused changes. One logical change per pull request is easier to review and to audit.
3. Commit with [Conventional Commits](https://www.conventionalcommits.org/):

   ```
   feat(core): read Claude Code's cached usage snapshot
   fix(app): keep the last snapshot when the cache read fails
   docs: clarify what Live mode sends
   ```

   Common types: `feat`, `fix`, `docs`, `test`, `refactor`, `perf`, `build`, `ci`, `chore`. Common scopes: `core`,
   `app`, `ci`. Breaking or privacy-relevant changes should say so in the commit body.
4. Run `make format`, `make lint` and `make test-all` before pushing.
5. Open a pull request against `main` and fill in the template.

## Tests

Tests are required for new behavior and for bug fixes. There are two suites:

- **Core** (`Core/Tests/QuotaRingCoreTests`): everything that does not need a UI. `make test`, which needs only the Swift
  toolchain.
- **App** (`AppTests`): the app's own logic: the settings store, the welcome window's model, what the menu bar shows,
  `AppModel`, the data engine's cache and transcript handling, the ring renderer and the notification texts.
  `make test-app` generates the Xcode project and runs the `QuotaRingAppTests` scheme with `xcodebuild`, unsigned.
  `make test-all` runs both. CI runs the app tests in the build jobs, on the newest Xcode and on Xcode 16.4.

Rules for both:

- Use [Swift Testing](https://developer.apple.com/documentation/testing): `import Testing`, `@Test`, `#expect`.
- Put pure logic in `Core` so it can be tested with `swift test --package-path Core` and no UI.
- Fixtures live alongside the tests under `Core/Tests`. They must be sanitized: no real tokens, account ids, email
  addresses, project names or conversation text. Use obviously fake values (for example `sk-ant-oat01-TEST`).
  Never copy real contents of `~/.claude.json` or the Keychain into the repository.
- Code that reads Claude's files must be tested with truncated, malformed and oversized input. Claude Code rewrites
  these files while we read them.
- Do not write tests that touch the real Keychain, the real `~/.claude*` or the real network. Use stubs and temporary
  directories.

Rules for the App tests in particular:

- The test bundle is **hostless**: it has no `TEST_HOST`, so running it never starts QuotaRing (which would read the real
  Claude files and may run programs). The app's sources, except `QuotaRingApp.swift` (it has `@main`) and the resources,
  are compiled into the bundle instead. Do not turn it into a hosted test.
- Every test makes its own `TestSandbox` (`AppTests/Support`): a folder in the temporary directory and a preferences
  suite named by a path inside it, so nothing lands in `~/Library/Preferences`. Pass that suite to
  `SettingsStore(defaults:persistentDomain:)`; never use `.standard` or the app's own domain. Remove the sandbox with
  `defer { sandbox.remove() }`.
- A type that can only be tested by reading real paths gets a small injection point (an initializer parameter whose
  default is today's behavior), or is left untested. `UsageEngine.start()` is such a case: it looks for the real
  `claude` tool, so tests call `refresh` and `setPopoverOpen` on an engine pointed at a temporary Claude config
  directory instead.
- Do not create views or windows (`NSView`, `NSHostingView`, `NSWindow`) in a test: the bundle has no running
  application to host them, and creating one traps. Keep a view's decisions in a plain type or property and test that
  (see `StatusPresentation` and `NoDataSection.offer`).
- Suites that test `@MainActor` types are `@MainActor`.

## Style

- Format with `swift format` using the repository's `.swift-format` (4-space indent, 120 columns). `make format` applies
  it and `make lint` enforces it; CI runs `make lint`.
- Swift 6 language mode with strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`). Fix warnings instead of
  silencing them.
- Log with `os.Logger` and privacy annotations. Never log anything derived from a token, and avoid logging file
  contents.
- All user-facing strings go through `String(localized:)` or `LocalizedStringKey`, with English as the base language.
  Translations live in `App/Resources/Localizable.xcstrings`. Turkish is maintained; to propose another language, open
  an issue first. See [Localization](#localization) for how to add the strings.
- Respect accessibility: add VoiceOver labels to new controls and honor Reduce Motion.
- Do not use Anthropic or Claude logos or marks.

## Localization

English is the base language and Turkish is maintained. **Every new user-facing string needs a Turkish translation in
the same pull request.**

The app's strings live in the String Catalogs `App/Resources/Localizable.xcstrings` and
`App/Resources/InfoPlist.xcstrings`. Building in Xcode keeps the catalog up to date, but **command-line builds
(`make build`, `xcodebuild build`) do not update it**, so a string you add in code is not in the catalog until you
export the localizations. From the repository root:

```sh
make generate
xcodebuild -exportLocalizations -project QuotaRing.xcodeproj -localizationPath build/l10n -exportLanguage tr
```

The export extracts the strings from the code into the catalog and writes `build/l10n/tr.xcloc`. Open
`build/l10n/tr.xcloc/Localized Contents/tr.xliff`. A new string is a `<trans-unit>` with a `<source>` and no `<target>`
yet: add `<target state="translated">your Turkish text</target>` after the `<source>`, then import the file:

```sh
xcodebuild -importLocalizations -project QuotaRing.xcodeproj -localizationPath build/l10n/tr.xcloc
```

Check that `git diff App/Resources` shows your keys with a `translated` Turkish value, and that running the export a
second time changes nothing. Keep format specifiers and Markdown in the strings as they are (`%@`, `%lld`, `%1$@`,
`**bold**`, backticks), and leave Claude, Claude Code, QuotaRing and Anthropic untranslated.

The relative times and durations from Core ("3 min ago") are plain `.strings` files, which you edit by hand:
`Core/Sources/QuotaRingCore/Resources/en.lproj/Localizable.strings` and `.../tr.lproj/Localizable.strings`. A test fails
if the two have different keys or format specifiers.

## Pull request checklist

The [pull request template](.github/pull_request_template.md) includes this list:

- [ ] Focused change, Conventional Commit messages
- [ ] `make test-all`, `make lint` and `make build` pass
- [ ] New logic has tests; fixtures contain no real data
- [ ] No tokens, credentials or real usage data anywhere (code, fixtures, logs, screenshots)
- [ ] No new network hosts, telemetry or third-party runtime dependencies
- [ ] Strings localized (English and Turkish); accessibility labels added
- [ ] Docs and `CHANGELOG.md` (`[Unreleased]`) updated if behavior changed
- [ ] The privacy and security impact section is filled in

## Screenshots and issue reports

Use `make demo` for screenshots so your real usage never appears. When reporting a bug, do not paste tokens or logs that
contain secrets.

## Releases

Releases are cut by the maintainer from a version tag and built in CI: Developer ID signed, notarized, with a
`SHA256SUMS` file and a GitHub build-provenance attestation. Contributors never need signing keys. The maintainer's
checklist is in [docs/RELEASING.md](docs/RELEASING.md).
