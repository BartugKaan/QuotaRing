# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First public release, planned as 0.1.0.

### Added

- Menu bar ring showing the remaining share of the 5-hour Claude session limit, with optional percentage text and an
  orange (20% remaining or less) and red (5% or less) warning tint.
- Staleness display: when the numbers are older than two refresh intervals (10 minutes by default), the menu bar dims
  the percentage and draws a dashed arc on a dashed faint track, shows "–" with a dashed track alone instead of a number
  when that session window has already reset, and the popover adds a hint.
- Cache problems are shown: if Claude Code's cache file exists but is too large or cannot be opened, or stays malformed
  for 90 seconds, the popover says "Can't read Claude Code's usage cache (…)". A cached snapshot dated more than
  5 minutes in the future is rejected.
- Popover with the session limit (remaining percentage, reset countdown and clock time), weekly limits for all models
  and for model-specific limits, limits of kinds QuotaRing does not know yet (shown generically, titled from the
  endpoint's name), extra usage when enabled, and Anthropic's own weekly "where it went" breakdown when available.
- Local activity view built from Claude Code transcripts: tokens by model, top projects, and a 7-day chart, for the
  current session, today or the last 7 days. Transcript entries older than 8 days are dropped from memory.
- Token-free default mode that reads only the `cachedUsageUtilization` key of Claude Code's cache in `~/.claude.json`
  (plus the account id, compared with the signed-in account and dropped) and the local transcripts in
  `~/.claude/projects`. No credentials and no network access.
- Opt-in Live mode that reads Claude Code's OAuth token read-only from the Keychain and requests
  `api.anthropic.com/api/oauth/usage`. The token is re-read on every poll, never stored, logged or refreshed, and
  never sent when expired. With a custom config directory only that directory's own Keychain item is read.
- Opt-in auto-refresh ("Refresh with Claude Code") for Claude desktop app users: QuotaRing runs Claude Code's own
  `claude -p "/usage" --safe-mode --no-session-persistence --output-format json` in the background when the numbers are
  older than the refresh interval (at most every 2 minutes, paused while asleep or offline, with Live mode's back-off;
  the Refresh button runs it too, at most once a minute), then re-reads the cache at once. It makes no model request and
  QuotaRing handles no credentials for it: Claude Code uses and renews its own login. Offered in the first-run window (a
  checkbox, pre-checked, recorded only when one of the window's buttons is pressed; closing the window turns nothing on) and in Settings → Data behind a consent sheet that shows the exact command; Settings shows the
  tool's path and version, lets you choose another `claude`, and shows the status. The popover's out-of-date notice
  offers "Turn on auto-refresh…" (it opens Settings, never switches anything on), and problems such as "not signed in"
  are shown there.
- Auto-refresh safety: the tool is found in the file you chose, the Claude Code builds bundled with the Claude desktop
  app (newest first) or the usual install locations, and used only if it resolves to a regular executable owned by you
  or root, not writable by others, whose `--version` says "(Claude Code)" and whose `--help` lists `--safe-mode` and
  `--no-session-persistence` (an older Claude Code is skipped, and reported as too old when it is the only one). It runs
  without a shell, with a constant argument array, a from-scratch environment that turns Claude Code's auto-updater off
  (`DISABLE_AUTOUPDATER=1`; a background run never updates Claude Code) and asks Claude Code not to send telemetry or
  error reports (`DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`), `/dev/null` as input and its own empty working
  folder, is stopped after 30 seconds or 256 KB of output, and its output is never logged or stored. Any sign of a model
  request in the result (turns, cost or tokens) turns auto-refresh off and says why.
- Live-mode consent: it is recorded as soon as you click "Enable Live mode"; in the first-run window only the first
  Keychain read waits for the notification prompt to settle (at most 15 seconds). The consent settings ignore
  command-line launch arguments. If you deny the Keychain prompt, Live mode stops there (no other Keychain item, no
  credentials file) and says so; it does not ask again until you press Refresh, turn Live mode off and on, or relaunch
  QuotaRing.
- Account safety: if the cache belongs to a different account than the one signed in to Claude Code, the cached, the
  saved and the live numbers are all dropped, and the saved snapshot is deleted from disk.
- The last good snapshot is saved to `~/Library/Application Support/QuotaRing/last-snapshot.json` (usage percentages and
  reset times, weekly breakdown, extra-usage flag and percentage without money amounts, limit metadata and the config
  directory it belongs to; never tokens; folder mode 700, file mode 600), so the ring is meaningful right after launch.
- Source selection by freshness, with the source and age shown in the UI ("Claude Code · 3 min ago", "Live · 1 min
  ago").
- Gentle polling: 5-minute default (3, 5, 10 or 15 minutes selectable) with jitter, exponential back-off that honors
  `Retry-After`, a 60-second manual refresh cooldown, and pausing while asleep or offline.
- Local notifications when session usage crosses configurable thresholds (default 80% and 95% used), once per window,
  and an optional notice when the session resets, sent on time from the local clock (checked every 30 seconds) even
  when no new data has arrived.
- Settings for launch at login, refresh interval, ring showing remaining or used, percentage text, notification
  thresholds, Claude config directory, auto-refresh and Live mode consent.
- First-run onboarding that explains what is read and sent before any Keychain access.
- Demo mode (`make demo` or the `--demo` launch argument) that uses fixture data and touches no Keychain, network or
  Claude files.
- English and Turkish localization (app, Info.plist and relative times), light and dark mode, VoiceOver labels and
  Reduce Motion support.
- Generated app icon with a ring motif.
- Open-source project files: README, CONTRIBUTING, Code of Conduct, security policy, MIT license, issue forms, pull
  request template, architecture overview.
- Continuous integration (tests, lint, unsigned build on the newest Xcode, plus tests and an unsigned build on Xcode
  16.4, the minimum supported version), CodeQL analysis, Dependabot for GitHub Actions, and a release pipeline that
  produces a Developer ID signed and notarized DMG and zip with `SHA256SUMS` and a GitHub build-provenance attestation.
  XcodeGen is installed from a pinned release with a verified SHA-256 checksum instead of Homebrew.

### Known limitations

- Only the `claude` command-line tool updates the usage cache that the default mode reads (a session or `/usage`). The
  Claude desktop app does not (verified on 2026-10-21), so if you use only the desktop app, turn on auto-refresh (it
  uses the Claude Code build bundled with the desktop app, or a `claude` you installed, signed in once). Without it,
  run `claude` or `/usage` now and then, or use Live mode, which stays fresh for roughly as long as Claude Code's login token is valid (about 8 hours
  after the CLI last ran).

### Security

- Not sandboxed by design (it must read Claude Code's files and a Keychain item created by another program); the
  reasoning and the threat model are in [SECURITY.md](SECURITY.md).
- No telemetry, analytics, crash reporting or update checks, and no third-party runtime dependencies.
- Auto-refresh executes one local program, Claude Code's `claude`, only with consent and only after validating it; the
  consent and the chosen path cannot be set through launch arguments. The details are in [SECURITY.md](SECURITY.md).

[Unreleased]: https://github.com/BartugKaan/QuotaRing/commits/main
