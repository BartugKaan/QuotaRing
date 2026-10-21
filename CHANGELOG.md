# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First public release, planned as 0.1.0.

### Added

- Menu bar ring showing the remaining share of the 5-hour Claude session limit, with optional percentage text and an
  orange (20% remaining or less) and red (5% or less) warning tint.
- Popover with the session limit (remaining percentage, reset countdown and clock time), weekly limits for all models
  and for model-specific limits, extra usage when enabled, and Anthropic's own weekly "where it went" breakdown when
  available.
- Local activity view built from Claude Code transcripts: tokens by model, top projects, and a 7-day chart, for the
  current session, today or the last 7 days.
- Token-free default mode that reads only the `cachedUsageUtilization` key of Claude Code's cache in `~/.claude.json`
  and the local transcripts in `~/.claude/projects`. No credentials and no network access.
- Opt-in Live mode that reads Claude Code's OAuth token read-only from the Keychain and requests
  `api.anthropic.com/api/oauth/usage`. The token is re-read on every poll, never stored, logged or refreshed, and
  never sent when expired.
- Source selection by freshness, with the source and age shown in the UI ("Claude Code · 3 min ago", "Live · 1 min
  ago").
- Gentle polling: 5-minute default (3, 5, 10 or 15 minutes selectable) with jitter, exponential back-off that honors
  `Retry-After`, a 60-second manual refresh cooldown, and pausing while asleep or offline.
- Local notifications when session usage crosses configurable thresholds (default 80% and 95% used), once per window,
  and an optional notice when the session resets.
- Settings for launch at login, refresh interval, ring showing remaining or used, percentage text, notification
  thresholds, Claude config directory and Live mode consent.
- First-run onboarding that explains what is read and sent before any Keychain access.
- Demo mode (`make demo` or the `--demo` launch argument) that uses fixture data and touches no Keychain, network or
  Claude files.
- English and Turkish localization, light and dark mode, VoiceOver labels and Reduce Motion support.
- Generated app icon with a ring motif.
- Open-source project files: README, CONTRIBUTING, Code of Conduct, security policy, MIT license, issue forms, pull
  request template, architecture overview.
- Continuous integration (tests, lint, unsigned build), CodeQL analysis, Dependabot for GitHub Actions, and a
  release pipeline that produces a Developer ID signed and notarized DMG and zip with `SHA256SUMS` and a GitHub
  build-provenance attestation.

### Security

- Not sandboxed by design (it must read Claude Code's files and a Keychain item created by another program); the
  reasoning and the threat model are in [SECURITY.md](SECURITY.md).
- No telemetry, analytics, crash reporting or update checks, and no third-party runtime dependencies.

[Unreleased]: https://github.com/BartugKaan/QuotaRing/commits/main
