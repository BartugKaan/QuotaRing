# QuotaRing — Design

- Date: 2026-10-20
- Status: Draft (awaiting owner approval)
- Owner: Bartuğ Kaan Çelebi (@BartugKaan)
- Lead developer: Claude

## 1. Intent

QuotaRing is a macOS menu bar app that shows, at a glance, how much of the
rolling **5-hour Claude subscription limit** is left — as a ring in the menu
bar, next to the battery and Wi-Fi icons. Clicking it opens a popover with a
clear breakdown of session, weekly and local usage.

Why it exists: similar apps exist, but the owner does not trust them because
"it is not clear what they put inside". **Trust is the product.** QuotaRing is
small, open source, auditable, talks to exactly one host (Anthropic), never
stores or refreshes credentials, and has no telemetry. A person should be able
to read the code in an afternoon and know exactly what it does.

Success looks like:

1. The owner glances at the menu bar and immediately knows how much of the
   5-hour limit remains and when it resets.
2. One click shows weekly limits and where the tokens went (models, projects,
   days).
3. Anyone can download a signed, notarized build from GitHub Releases, or build
   it from source, and the repository makes it obvious how to contribute and
   how to report a security problem.

## 2. Goals (v1)

- **G1 Menu bar ring.** A ring showing the remaining share of the 5-hour
  session limit (full ring = whole limit available). Optional percentage text
  beside it. Tints to warn when little is left.
- **G2 Popover.** Session (remaining %, reset countdown and clock time),
  weekly limits (all models + any model-scoped limits), extra usage when
  enabled, local activity (tokens by model, by project, 7-day chart), last
  updated time, manual refresh, settings, quit.
- **G3 Notifications.** Local notifications when session usage crosses
  configurable thresholds (default 80 % and 95 % used), once per window.
  Optional "session reset" notification (default off).
- **G4 Settings.** Launch at login, refresh interval, ring shows remaining vs
  used, percentage text on/off, notification thresholds, Claude config
  directory, usage-API consent toggle.
- **G5 Token-free by default, consent for live mode.** By default QuotaRing
  reads only Claude Code's own cached usage snapshot and local transcripts —
  no credentials, no network (§6.0). "Live mode" (Keychain read + Anthropic
  request) is opt-in: onboarding explains exactly what is read and where it
  is sent before any Keychain access. Revocable in Settings.
- **G6 Open-source project quality.** README, CONTRIBUTING, Code of Conduct,
  SECURITY policy, LICENSE, CHANGELOG, issue/PR templates, CI, CodeQL,
  Dependabot (Actions), signed + notarized release pipeline.
- **G7 Localization.** English (base) and Turkish.

## 3. Non-goals (v1)

- Dollar cost estimates (pricing tables go stale; subscription limits are not
  token-priced). Candidate for later.
- claude.ai web session cookies or any web scraping.
- Refreshing OAuth tokens.
- Launching the `claude` CLI to make it refresh its login. Verified that an
  interactive start does refresh it, but each launch creates a new Claude Code
  session entry, may self-update and starts the user's MCP servers — too many
  side effects for a background helper.
- Auto-update framework (Sparkle) — candidate for v1.1.
- Token-free "statusLine bridge" live source — candidate for v1.1 (see §11).
- Homebrew cask, widgets, Windows/Linux, Anthropic Console (API-key) usage.

## 4. Anti-goals (failure even if it "works")

- Writing, refreshing, persisting, logging or caching the OAuth token anywhere
  (disk, UserDefaults, logs, crash reports, pasteboard).
- Any network traffic to a host other than `api.anthropic.com`. No telemetry,
  analytics, crash-reporting SDKs or update pings in v1.
- Modifying Claude Code's files, settings or Keychain items.
- Asking the user to paste secrets.
- Impersonating Claude Code (e.g. spoofing its User-Agent to dodge rate
  limits). QuotaRing identifies itself honestly.
- Third-party runtime dependencies in v1 (supply-chain surface = Apple SDKs only).
- Using Claude/Anthropic logos, the sunburst mark, or implying affiliation.

## 5. Constraints and facts

- **Platform:** macOS 14 Sonoma or later; built with Xcode 26 / Swift 6
  language mode, strict concurrency. Apple Silicon and Intel (universal).
- **Distribution:** outside the Mac App Store. Developer ID signed, Hardened
  Runtime, notarized. **Not sandboxed**: the app must read `~/.claude/` and a
  Keychain item created by another program; both are impossible or brittle
  under App Sandbox. This is documented in SECURITY.md.
- **The usage endpoint is undocumented** (`GET /api/oauth/usage`, used by
  Claude Code's `/usage`). It can change without notice → decode defensively,
  fail soft, never crash.
- **Rate limiting is harsh** and reportedly per token (persistent 429s, often
  without `Retry-After`, some users even at 10-minute polls). → Default refresh
  every 5 minutes with jitter, back off, keep showing the last good data with
  its age.
- **Credentials** (verified on the owner's Mac, 2026-10-20): login Keychain,
  generic password, service `Claude Code-credentials`; secret is JSON
  `{"claudeAiOauth": {accessToken, refreshToken, expiresAt (ms epoch),
  refreshTokenExpiresAt, scopes, subscriptionType, rateLimitTier},
  "mcpOAuth": {...}}`. Community reports say some Claude Code versions use
  `Claude Code-credentials-<first 8 hex of sha256(configDir)>`, and that the
  plain item may contain only `mcpOAuth`. Access tokens live ~8 h; Claude Code
  refreshes them itself. Refresh tokens are single-use/rotating — a third-party
  refresh logs the user out of Claude Code. Hence: **never refresh.**
- **Desktop-app users have a stale CLI token** (verified on the owner's Mac,
  2026-10-20): the owner mainly uses the Claude desktop app, which hands auth
  to its embedded Claude Code itself (host-managed refresh), so the Keychain
  item's `claudeAiOauth` token had expired ~19 days earlier. A live call with
  it returned `401` `{"type":"error","error":{"type":"authentication_error",
  "message":"OAuth access token has expired. ..."},"request_id":"req_..."}`
  with header `x-should-retry: false`. Handling this case well is a v1
  requirement, not an edge case (see §6.1 "Expired token").
- **Claude Code caches the usage response** (verified 2026-10-21) in
  `~/.claude.json` under `cachedUsageUtilization`:
  `{fetchedAtMs, accountUuid, utilization: <full /api/oauth/usage body>}`.
  The file is mode 0600 and is rewritten often by every Claude Code process.
  It also holds unrelated, potentially sensitive config (MCP server
  definitions, account info), so only that one key may be extracted.
- **Verified live response** (2026-10-21, sanitized fixture captured):
  `limits[].percent` is **percent used** — `weekly_all` 18 matched `/usage`
  "18% used". `five_hour.utilization` is also percent used (0–100, int or
  float). New fields seen: `five_hour.locked_reason`, `seven_day_cowork`,
  `seven_day_breakdown {as_of, window_started_at, rows[{key, display_name,
  percent}]}` (e.g. Claude Code 44 %, Chats 1 %, Cowork 54 %, Other 1 %),
  `weekly_scoped_shares[{limit_index, used_percent_of_weekly,
  allowance_percent_of_weekly}]`, `spend {used {amount_minor, currency,
  exponent}, …}`, `member_dashboard_available`, plus ~20 obfuscated `null`
  experiment keys. `resets_at` had microseconds and `+00:00`.
- `claude auth status` reports `loggedIn: true` with an expired access token
  and does **not** refresh it; starting `claude` interactively does.
- **Local transcripts** `~/.claude/projects/**/*.jsonl` are an internal format
  that changes between versions; retention defaults to 30 days. Only Claude
  Code usage appears there (not claude.ai chat). Treat as best-effort detail,
  never as the source of the limit percentage.
- **Policy gray area:** Anthropic's Claude Code legal page says developers "may
  not collect, store, or intermediate Claude.ai credentials or session
  tokens". QuotaRing reads the user's own token locally, in memory, solely to
  ask Anthropic for that same user's usage; it never stores or forwards it.
  The README states this plainly, plus a non-affiliation disclaimer.

## 6. Data sources

### 6.0 Source strategy

Three read-only sources; the limit percentage comes from the freshest of the
first two (compared by fetch time), the detail from the third.

1. **Claude Code cache (default, token-free).** `<home>/.claude.json`, or
   `D/.claude.json` when a custom config directory `D` is set. Check `stat`
   every 30 s; parse only when mtime/size changed; skip files > 50 MB.
   Extract `cachedUsageUtilization` and discard the rest of the document
   immediately (never log, store or keep it). Decode `utilization` with the
   same decoder as the live endpoint; age = now − `fetchedAtMs`. If several
   accounts are possible, prefer the entry whose `accountUuid` matches
   `oauthAccount.accountUuid` in the same file when present. **Never write
   this file.**
2. **Live endpoint (opt-in "Live mode").** Only after consent, only when the
   cached snapshot is older than the refresh interval, and only with a
   non-expired token (§6.1–6.3).
3. **Local transcripts** for tokens by model/project/day (§6.4).

The UI always shows where the numbers came from and how old they are
("Claude Code · 3 min ago" / "Live · 1 min ago").

### 6.1 Credential resolution (read-only, Live mode only)

Given the configured Claude config directory `D` (default `~/.claude`), try in
order and use the first candidate that contains a non-empty
`claudeAiOauth.accessToken`:

1. Keychain generic password, service `Claude Code-credentials`.
2. Keychain generic password, service
   `Claude Code-credentials-<sha256(NFC(D)) first 8 hex chars>`.
3. File `D/.credentials.json` — only if it is a regular file owned by the
   current user and not group/world readable; otherwise ignore it.

Rules:

- Read via the Security framework (`SecItemCopyMatching`). Re-read on **every**
  poll; never cache the token across polls; drop it right after the request.
- **Expired token:** if `expiresAt` is in the past (with 60 s skew), do not
  call the API; fall back to the cache source and show a quiet hint
  ("Live mode paused: Claude Code login expired — open `claude` once to
  renew"). Retry on the next poll. Never refresh, never launch the CLI.
- `D` for the hashed service name is the tilde-expanded, standardized absolute
  path without a trailing slash, symlinks not resolved, NFC-normalized. This
  naming is a community report and best effort. `D` can only be changed via the
  Settings picker (a launchd-started app cannot see `CLAUDE_CONFIG_DIR`).
  *(Lead developer's call.)*
- The token is wrapped in a `Secret` type whose `description`,
  `debugDescription` and reflection are redacted and which is not `Codable`.
- Nothing is read before the user grants consent in onboarding.
- Builder to verify: whether reading from QuotaRing triggers a Keychain access
  prompt, and whether it recurs every time Claude Code rewrites the item (~8 h).
  If it recurs, fall back to executing `/usr/bin/security
  find-generic-password -s <service> -w` with a fixed absolute path and
  argument array (no shell), and document the reason.

### 6.2 Usage API

- `GET https://api.anthropic.com/api/oauth/usage` — the URL is a compile-time
  constant. Not configurable (prevents token exfiltration via settings).
- Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
  `Accept: application/json`, `User-Agent: QuotaRing/<version>
  (+https://github.com/BartugKaan/QuotaRing)`.
- `URLSession` with an **ephemeral** configuration: no cookies, no URL cache,
  no credential storage, 15 s timeout, HTTPS only (ATS defaults).
- Status handling: 200 → decode; 401/403 → "needs re-login" state; 429 →
  back off honoring `Retry-After` (seconds or HTTP date) else exponential
  (5 → 10 → 20 → 30 min cap); 5xx / network error → back off, keep stale data.
- Decoding (tolerant; one bad entry must not discard the snapshot; unknown
  keys ignored):
  - Prefer `limits[]`: `{kind, group, percent (0–100), severity, resets_at,
    scope: null | {model: {id, display_name}, surface}, is_active}`. Known
    kinds: `session`, `weekly_all`, `weekly_scoped`; keep unknown kinds and
    show them generically.
  - Fallback to legacy keys `five_hour`, `seven_day`, `seven_day_opus`,
    `seven_day_sonnet`, `seven_day_oauth_apps` (`{utilization, resets_at}`,
    any may be `null`). Treat `utilization` as percent 0–100 and clamp.
  - `resets_at`: ISO 8601 with optional fractional seconds and offset, **or**
    epoch seconds number; may be `null`.
  - `extra_usage`: `{is_enabled, monthly_limit, used_credits, utilization,
    currency, decimal_places}` — money in minor units.
- The last good snapshot (percentages + reset times only, no secrets) is
  persisted to `~/Library/Application Support/QuotaRing/last-snapshot.json`
  so the ring is meaningful immediately at launch (marked stale).

### 6.3 Polling policy

- Default interval 5 min; options 3 / 5 / 10 / 15 min; ±10 % jitter.
- Manual refresh allowed, with a 60 s cooldown.
- Pause on system sleep and when offline (`NWPathMonitor`); refresh on wake /
  reconnect (respecting cooldown and back-off).
- Between polls the reset countdown keeps ticking locally; when `resets_at`
  passes, show the session as reset (0 % used, "waiting for fresh data").

### 6.4 Local transcripts (best effort)

- Scan `D/projects/**/*.jsonl` recursively (includes `subagents/`).
- Use lines with `type == "assistant"` that have `message.usage`; skip model
  `<synthetic>`.
- Dedupe **globally** by `message.id` (+ `requestId` when present); keep the
  per-field maximum (Claude Code writes one line per content block with
  repeated usage; forks copy parent ids).
- Token classes: input, output, cache write, cache read. Labelled
  "approximate" in the UI.
- Aggregations: per local day, per model family (display name), per project
  (last path component of `cwd`, fallback to the directory name). Windows:
  current 5 h session window (from `resets_at − 5 h` when known, else last
  5 h), today, last 7 days.
- Incremental: remember `(path, size, mtime, byteOffset)`; parse only appended
  bytes; full re-read on truncation; ignore an incomplete trailing line; skip
  lines > 10 MB. Runs on a background actor; triggered on popover open and
  every 60 s while the popover is open.
- Works without consent (no secrets involved).

## 7. UI

### 7.1 Menu bar item

- AppKit `NSStatusItem` (variable length) with a custom-drawn ring image
  (~16 pt, track at low alpha, arc = remaining share), template image so it
  matches the menu bar; optional text such as `72%`.
- Warning tint (non-template) at ≤ 20 % remaining (orange) and ≤ 5 % (red).
- Distinct visuals for: loading, no consent (local only), stale, login
  expired, error. Exact drawing is the builder's call.
- VoiceOver label, e.g. "QuotaRing: 72 percent of 5-hour limit remaining,
  resets in 2 hours 14 minutes".
- Left click → popover; right click → menu (Refresh, Settings…, About, Quit).

### 7.2 Popover (~340 pt wide, SwiftUI)

1. **Session:** large ring, "72 % left", "Resets in 2 h 14 m · 03:00".
2. **Weekly:** one row per weekly limit (All models; scoped e.g. Opus/Fable)
   with a progress bar and reset day/time. Extra usage row if enabled. When
   `seven_day_breakdown` is present, a compact "Where it went" bar (Claude
   Code / Chats / Cowork / Other) — Anthropic's own breakdown, covering all
   devices and claude.ai.
3. **Activity (local):** segmented control Session / Today / 7 days → total
   tokens, by model, top 5 projects; 7-day bar chart (Swift Charts).
4. **Footer:** source + age ("Claude Code · 3 min ago" / "Live · 1 min
   ago", stale/error hint), refresh button (re-reads the cache; also calls
   the endpoint in Live mode, cooldown-aware), settings, quit.

States without consent or data show a short explanation and a button to
enable live limits.

### 7.3 Settings and onboarding

- Settings tabs: General (launch at login via `SMAppService`, refresh
  interval, ring mode remaining/used, % text), Notifications (thresholds,
  reset notice), Data (config directory picker, live-limits consent toggle),
  About (version, license, repo, disclaimer).
- Onboarding window at first launch with the consent explanation (§6.1).
- Light/Dark mode, Reduce Motion respected, full VoiceOver labels.

## 8. Architecture

```
<repo root>
├─ Package.swift                 # QuotaRingCore library + tests (swift test, no Xcode project needed)
├─ Sources/QuotaRingCore/        # pure logic: models, decoding, credentials, API client, polling policy, log scanner, formatting
├─ Tests/QuotaRingCoreTests/     # Swift Testing + Fixtures/
├─ App/                          # app target: AppKit status item, SwiftUI views, Info.plist, entitlements, xcstrings, assets
├─ project.yml                   # XcodeGen spec; .xcodeproj is generated and git-ignored
├─ Makefile                      # setup / generate / build / test / lint / release helpers
├─ scripts/                      # release: sign, notarize, staple, dmg, checksums
├─ docs/                         # ARCHITECTURE.md, specs, plans
└─ .github/                      # workflows, templates, dependabot, CODEOWNERS
```

- Core is protocol-driven for testability: `CredentialSource`
  (`KeychainCredentialSource`, `FileCredentialSource`) + `CredentialResolver`;
  `HTTPTransport` + `UsageAPIClient`; `UsageResponseDecoder` → `UsageSnapshot`;
  `PollingPolicy` (pure function of last result, attempt, Retry-After,
  jitter); `TranscriptScanner` (actor) + `UsageAggregator` (pure).
- App layer: `AppModel` (`@MainActor @Observable`) owns polling, sleep/wake
  and reachability; `StatusItemController` (AppKit); `NotificationService`
  (fires each threshold once per window, keyed by `resets_at`);
  `SettingsStore` (UserDefaults, non-sensitive values only).
- Logging via `os.Logger` (subsystem = bundle id) with privacy annotations;
  tokens are never logged, even redacted.
- Bundle identifier: `io.github.bartugkaan.QuotaRing`. `LSUIElement = YES`
  (no Dock icon).
- Signing: project defaults to "Sign to Run Locally" so any contributor can
  build; the team ID lives in a git-ignored `Local.xcconfig` or CI secrets —
  never committed. The owner's local test builds use his Apple Development
  identity via `Local.xcconfig`, so a Keychain "Always Allow" grant survives
  rebuilds and prompt behavior matches signed releases. *(Lead developer's
  call.)*
- Demo mode: launch argument `--demo` feeds fixture data (no Keychain, no
  network, no transcripts) for README screenshots and UI work, so the owner's
  real usage is never published. *(Lead developer's call.)*
- App icon: a simple, programmatically drawn ring motif (no Claude/Anthropic
  marks), committed as a generated asset catalog. *(Lead developer's call.)*
- Formatting/linting with the toolchain's bundled `swift format` (no extra
  tool). XcodeGen installed via Homebrew (`make setup`).

## 9. Quality and security

- **Tests (Swift Testing):** the captured live fixture; Claude Code cache
  extraction (key present/missing, malformed, huge file, account match, other
  keys never surfaced); source selection by freshness; decoder fixtures
  (current `limits[]`, legacy-only,
  all-null, epoch and ISO `resets_at`, malformed entry, unknown kind,
  extra usage), credential parsing (missing `claudeAiOauth`, `mcpOAuth`-only,
  empty/expired token, insecure file permissions), resolver order, polling
  policy (Retry-After seconds/date, caps, jitter bounds), scanner (dedupe,
  synthetic skip, subagents, partial trailing line, truncation, incremental
  offsets), redaction (interpolating a `Secret` never reveals it),
  formatters, notification once-per-window logic.
- **CI (GitHub Actions, macOS runner):** `swift test`, `swift format lint`,
  XcodeGen + unsigned `xcodebuild build`; CodeQL for Swift; Dependabot for
  Actions; all actions pinned by commit SHA; least-privilege `permissions`.
- **Release (on `v*` tag, `release` environment with required reviewer):**
  import Developer ID cert into a temporary keychain → archive → export →
  `notarytool` (App Store Connect API key) → staple → DMG + zip →
  `SHA256SUMS` → GitHub build-provenance attestation → draft release.
  Secrets: `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
  `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`.
- **Security review** of the finished code (credential handling, network
  surface, logging, file parsing robustness) before the PR is marked ready.
- **Repository docs:** README (what/why, screenshot, install, build from
  source, how it works & privacy, FAQ, disclaimer), CONTRIBUTING (setup,
  workflow, commit style = Conventional Commits, PR checklist), CODE_OF_CONDUCT
  (Contributor Covenant 2.1; reporting channel is GitHub only — no personal
  email is published, per owner), SECURITY (private vulnerability reporting via
  GitHub advisories, threat model summary, why not sandboxed), CHANGELOG (Keep
  a Changelog), docs/ARCHITECTURE.md, issue forms (bug, feature), PR template,
  CODEOWNERS.
- **License:** MIT (lead developer's call; common for this kind of tool).

## 10. Repository and rollout

0. Commits in this repo use the owner's GitHub noreply address (repo-local
   git config), per owner.
1. Work on branch `feat/quotaring-v1` in `~/Desktop/development/VibeProject`.
2. Create **private** repo `BartugKaan/QuotaRing`, push, open a PR to `main`.
3. Owner tests locally. When approved: merge, make the repo public, enable
   private vulnerability reporting, branch protection, topics/description.
4. Owner creates a Developer ID Application certificate and App Store Connect
   API key, adds the secrets; first tagged release `v0.1.0`.

## 11. Owner decisions (2026-10-20)

- Data source: official usage endpoint + local transcripts.
- Name: QuotaRing. Distribution: Developer ID signed + notarized.
- Repo: private first; public after the owner has tested and approved.
- Policy gray area: proceed with explicit consent + plain README disclosure;
  if the endpoint becomes unusable, the app keeps working with local stats.
  Token-free statusLine bridge stays a v1.1 candidate.
- Live endpoint calls with the owner's credentials during development:
  allowed (a few requests; sanitized fixtures; token never printed).
- Q1 resolved (2026-10-21): no CLI launching (side effects, §3). Instead the
  default source became Claude Code's own cached snapshot, so QuotaRing needs
  no credentials at all unless Live mode is turned on. *(Lead developer's
  call after the owner's experiment.)*

## 12. Left to the builder

- Exact ring drawing, colors, spacing, typography, copy wording.
- Internal type names beyond those listed, file split, concurrency details.
- Notification copy and the onboarding layout.
- Whether to keep the statusLine bridge for v1.1 (token-free, official
  `rate_limits` from Claude Code's status line JSON; requires chaining the
  user's existing status line command).

## 13. Auto-refresh via Claude Code (added 2026-10-22, owner decision)

**Why:** the Claude desktop app never refreshes Claude Code's usage cache, so
desktop-only users saw out-of-date numbers until they ran `/usage` in a
terminal. The owner chose to automate that.

**Verified on the owner's Mac (Claude Code 2.1.287):**
`claude -p "/usage" --safe-mode --no-session-persistence --output-format json`
exits 0 in ~2 s, refreshes `cachedUsageUtilization` in `~/.claude.json`,
reports `num_turns: 0` and `total_cost_usd: 0` (no model request, no usage
spent), writes no session transcript, and `--safe-mode` starts no plugins,
hooks or MCP servers. `--bare` is unusable (it disables OAuth/Keychain).

**Behavior:**
- Opt-in "Refresh with Claude Code" (Settings → Data; offered in onboarding as
  recommended for Claude desktop app users). QuotaRing never reads credentials
  for this: Claude Code uses and renews its own login.
- Runs only when the cached snapshot is older than the refresh interval, never
  more often than every 120 s, paused while asleep or offline, with the same
  back-off as Live mode on failures; the Refresh button also triggers it
  (60 s cooldown). After a run, the cache loop re-reads immediately.
- Executes exactly the command above with a fixed argument array (no shell),
  `stdin` from `/dev/null`, a minimal environment (`HOME`, `USER`, `LOGNAME`,
  `LANG`, `PATH` = the binary's folder + `/usr/local/bin:/opt/homebrew/bin:
  /usr/bin:/bin`, `DISABLE_AUTOUPDATER=1`, and `CLAUDE_CONFIG_DIR` when a
  custom config dir is set), working directory
  `~/Library/Application Support/QuotaRing/cli` (0700), 30 s timeout (process
  killed), output capped at 256 KB and never logged.
- **Never auto-update** (fix round 1, 2026-10-22): the owner's npm Claude Code
  updated itself (2.1.287 → 2.1.308) and the update broke the install, so every
  run and check sets `DISABLE_AUTOUPDATER=1` (verified: cache refreshed in 2 s,
  0 turns / 0 cost, npm untouched). `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`
  must **not** be set: verified, it makes `/usage` return the stale cached
  numbers without a network call.
- Binary discovery (GUI apps don't see the shell `PATH`): the user-chosen path,
  then the Claude desktop app's bundled, signed builds
  `~/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude`
  (newest version first, numeric comparison, non-version folders ignored),
  then `~/.local/bin/claude`, `~/.claude/local/claude`,
  `~/.npm-global/bin/claude`, `/opt/homebrew/bin/claude`,
  `/usr/local/bin/claude`. Valid = resolves (symlinks followed) to a regular,
  executable file owned by the user or root and not group/world-writable.
  Usable = valid, `--version` output contains "(Claude Code)", and `--help`
  lists both `--safe-mode` and `--no-session-persistence` (same minimal env,
  10 s limit each, cached per resolved path + file identity). Candidates that
  are not usable are skipped; if a Claude Code was found but all are too old,
  the status is "unsupported version" with its path and version, else "not
  found". Settings shows the binary used and its version (the desktop app's
  build as "Claude app (<version>)", full path as tooltip).
- Safety net: the JSON result must be `type: result`, `is_error: false`,
  `num_turns: 0`, `total_cost_usd: 0`. If a future Claude Code sends `/usage`
  to the model instead (turns or cost > 0), the feature turns itself off and
  says why. Not logged in / not found / timeout / error → a clear status and
  back-off.
- Supersedes the §3 non-goal "Launching the `claude` CLI": the side effects
  that ruled it out do not occur with this invocation.
