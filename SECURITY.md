# Security Policy

QuotaRing is a small app that can, in its opt-in Live mode, handle a sensitive secret (Claude Code's OAuth token), and,
with opt-in auto-refresh, execute a program on your Mac (Claude Code's `claude` tool). Security reports are taken
seriously and are very welcome.

## Supported versions

QuotaRing is pre-1.0. Only the latest release receives security fixes.

| Version | Supported |
| --- | --- |
| Latest release (0.1.x) | Yes |
| Anything older, or unreleased commits | No |

## Reporting a vulnerability

**Do not open a public issue or pull request for a security problem.**

Use GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/BartugKaan/QuotaRing/security) of this repository.
2. Choose **Report a vulnerability**, or open [a new advisory](https://github.com/BartugKaan/QuotaRing/security/advisories/new)
   directly.
3. Describe the problem, how to reproduce it, the affected version and the impact you see.

Please **do not include real tokens, credentials or private files** in a report. Fake values or a description are enough.
If you accidentally exposed a real token, treat it as compromised: sign out of Claude Code and sign in again, and review
the active sessions on your Anthropic account.

No personal email address is published for this project; GitHub private reporting is the only channel.

### What to expect

QuotaRing is maintained by one person in their spare time. These are best-effort targets for a solo maintainer, not
guarantees:

| Step | Best-effort target |
| --- | --- |
| Acknowledge your report | within 7 days |
| Initial assessment (accepted, needs info, or declined, with reasons) | within 14 days |
| Fix or mitigation for a confirmed high-severity issue | within 30 days |

We use coordinated disclosure: please give us a reasonable chance to ship a fix before publishing details. We will credit
you in the release notes and advisory unless you prefer to stay anonymous. Good-faith research that follows this policy
and respects other people's data is welcome.

## Scope

In scope:

- Any path by which an OAuth token could be written to disk, logged, cached, copied, sent to a host other than
  `api.anthropic.com`, or otherwise exposed.
- Any network traffic to a host other than `api.anthropic.com`, or any telemetry.
- Any write to Claude Code's files (`~/.claude.json`, `~/.claude/**`) or Keychain items.
- Any way to make QuotaRing execute a program other than a validated Claude Code tool, run it with other arguments or
  environment, run it without the user's consent, or keep, log or forward what it prints.
- Crashes, hangs or unbounded resource use triggered by malformed, hostile or huge `~/.claude.json`, transcript or API
  response data.
- Weaknesses in the build, signing, notarization or release pipeline (for example unpinned actions or tools, leaked
  secrets, tampered artifacts).
- Excessive entitlements or other hardening gaps in the shipped app.

Out of scope:

- Vulnerabilities in Claude Code, the Claude apps or Anthropic's services. Report those to Anthropic.
- Attacks that already require malware running as your user, root access or physical access. Such an attacker can read
  the same files and Keychain items as QuotaRing without QuotaRing's help.
- Questions about Anthropic's terms of service. See the README for QuotaRing's position.
- The fact that the endpoint is undocumented or rate-limited.

## Threat model summary

**What is worth protecting**

1. Claude Code's OAuth access token, which QuotaRing handles only in Live mode.
2. The contents of `~/.claude.json` (it also holds MCP server definitions and account details) and of Claude Code
   transcripts, which are your conversations.
3. The integrity of the app you run, and of the one program it may run (auto-refresh).
4. Your usage limits: nothing QuotaRing does may send a prompt to a model.

**Controls**

| Risk | Control |
| --- | --- |
| Token leaks to disk or logs | The token is read from the Keychain on every poll, wrapped in a `Secret` type whose description, debug description and reflection are redacted and which is not `Codable`, used for one request, then dropped. It is never put in UserDefaults, files, logs, crash reports or the pasteboard. Logging uses `os.Logger` with privacy annotations and never includes token-derived data. |
| Token sent to the wrong place | The endpoint is a compile-time constant (`https://api.anthropic.com/api/oauth/usage`), not a setting, so configuration or a hostile file cannot redirect it. HTTPS only, with App Transport Security defaults. |
| Cross-request leakage | Requests use an ephemeral `URLSession`: no cookies, no URL cache, no credential storage. |
| Breaking the user's Claude Code login | QuotaRing never refreshes tokens (refresh tokens are single-use). An expired token is not sent anywhere. The only `claude` run is the opt-in auto-refresh command, in which Claude Code uses and renews its own login exactly as when you run it yourself. |
| Executing a local program (auto-refresh, opt-in) | Off until the user agrees in onboarding or in a consent sheet that shows the exact command; the consent, the chosen path and the Claude config directory (passed on as `CLAUDE_CONFIG_DIR`) are read from saved preferences only, never from launch arguments. The tool is looked for only in a fixed list of places (the one file the user chose, the Claude Code builds bundled with the Claude desktop app in `~/Library/Application Support/Claude/claude-code`, newest first, then the usual install locations), and used only if, after following symbolic links, it is a regular executable file owned by the user or root and not group- or world-writable, its `--version` output says "(Claude Code)", and its `--help` lists `--safe-mode` and `--no-session-persistence` (only definitive answers are remembered, per file identity, and the file is checked again after it changes; an older Claude Code is skipped, never run without those options). Right before every execution, each check and the run itself, the file is inspected again and must still be the same resolved file with the same identity, or it is not run (a change in the instant between that inspection and the launch is not excluded). It runs with a constant argument array (`-p "/usage" --safe-mode --no-session-persistence --output-format json`) and no shell, an environment built from scratch (`HOME`, `USER`, `LOGNAME`, `LANG`, `PATH` with the system folders before `/usr/local/bin` and `/opt/homebrew/bin`, `DISABLE_AUTOUPDATER=1` so a background run or check never updates Claude Code, `DISABLE_TELEMETRY=1` and `DISABLE_ERROR_REPORTING=1`, which ask Claude Code not to send telemetry or error reports (honoring that is up to Claude Code), and `CLAUDE_CONFIG_DIR` for a custom config directory; `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is deliberately not set, because it makes `/usage` return stale cached numbers), standard input from `/dev/null`, standard error discarded, and an empty private working folder (mode 700). A 30 s timeout, a 256 KB output cap and cancellation stop the whole process group (`SIGTERM`, then `SIGKILL`). The output is parsed in memory and dropped; only an outcome name is logged. |
| A consent outliving a changed feature | Each consent (Live mode, auto-refresh) is saved together with the version of the feature it was given for (`UsageAPI.consentVersion`, `CLIRefreshCommand.consentVersion`), read from saved preferences only. A release that changes the endpoint, the request, the command, its environment or the data read raises that version, and a consent given for another version does not count: the feature stays off until the user agrees again. Turning a feature off clears its consent and version. |
| Credentials during auto-refresh | None handled: QuotaRing reads no token, Keychain item or credentials file for it. Claude Code signs in as itself. |
| Spending usage by accident | `/usage` makes no model request (verified: zero turns, cost and tokens). Every result is checked for exactly that; any turn, cost or token count turns auto-refresh off and tells the user. |
| Reading more than necessary | From `~/.claude.json` only the `cachedUsageUtilization` key is kept; the rest is dropped immediately. The one other value looked at is the account id (`oauthAccount.accountUuid`), which is compared with the id in the cache entry and then dropped. Transcripts are reduced to timestamp, model, token counts, project folder name and message id, and entries older than 8 days are dropped from memory. A credentials file is accepted only if it is a regular file owned by you and not group or world readable. Nothing is read from the Keychain before you opt in. The consent settings are read from QuotaRing's saved preferences only, so command-line launch arguments cannot enable Live mode. |
| Another account's numbers | If the cache entry and `oauthAccount` name different accounts, the cached, the saved and the live numbers are all dropped and the saved snapshot is deleted from disk. A custom config directory reads only its own Keychain item (the plain `Claude Code-credentials` item belongs to the default account). |
| Repeated Keychain prompts | If you deny the Keychain prompt, Live mode stops there (it reads neither another Keychain item nor the credentials file) and does not ask again until you press Refresh, turn Live mode off and on, or relaunch QuotaRing. |
| Damaging Claude's files | QuotaRing only reads them. It has no code path that writes `~/.claude.json`, `~/.claude/**` or Keychain items. |
| Hostile or corrupted input | Defensive parsing that never trusts shape or size: files over 50 MB and transcript lines over 10 MB are skipped, and Claude Code's cache file is checked and read through one open descriptor, so a FIFO or other special file is refused without blocking. A Live response body over 1 MiB is refused (a larger declared length before the body is read, a longer stream as soon as it passes the limit). At most 32 limits and 16 breakdown rows (de-duplicated by key) are kept from one response; an `extra_usage.decimal_places` outside 0 to 6 and a currency that is not a three-letter code are dropped. Truncated or malformed JSON keeps the previous snapshot, unknown keys are ignored. The decoder tolerates bad entries rather than crashing. |
| Supply chain (runtime) | No third-party runtime dependencies. The attack surface is Apple's SDKs and this repository. |
| Supply chain (build and release) | CI uses least-privilege `permissions` and pins every GitHub Action to a commit SHA, with Dependabot keeping them current (it proposes a new version only once it is a week old). XcodeGen, the one build tool installed from the network, is pinned to an exact release and verified against a SHA-256 checksum before it is unpacked (`scripts/ci/install-xcodegen.sh`). Releases are built in CI on a protected `release` environment, signed with a Developer ID certificate (imported into a temporary keychain as a non-extractable key that only `codesign` may use), checked to carry no entitlements, notarized by Apple, published with `SHA256SUMS` and a GitHub build-provenance attestation. CodeQL scans the Swift code and the workflow files themselves on every pull request, every push to `main` and weekly. `main` takes changes only through pull requests that pass CI (Test, Lint, Build, the Xcode 16.4 floor) and have no high-severity CodeQL alert; force pushes and deletion are blocked. Only the maintainer can create, move or delete `v*` tags, which start a release, and the `release` environment that holds the signing secrets accepts only `v*` tags and waits for the maintainer's approval. Outside contributors' workflow runs need the maintainer's approval, only GitHub's own actions are allowed and they must be pinned to a full commit SHA. Secret scanning with push protection and Dependabot security alerts are on, and published releases are immutable. |
| Telemetry | None: no analytics, crash reporting SDKs or update pings. |

**Not defended against**

- Malware already running as you. It can read the same files, and it can request the same Keychain item. It can also
  replace the `claude` tool that auto-refresh runs (any file you own is yours to change). QuotaRing refuses a file that
  is not owned by you or root, or whose permission bits let its group or other users write it; it does not check access
  control lists or the folders above the file, so a folder another account can write to is not detected.
- The interpreter of a script-based `claude`. An npm install's `claude` is a script that starts with
  `#!/usr/bin/env node`, so `node` is looked up on the `PATH` QuotaRing builds (the tool's folder, then
  `/usr/bin:/bin:/usr/sbin:/sbin`, then `/usr/local/bin:/opt/homebrew/bin`). Only the `claude` file itself is checked
  for owner and permission bits; the interpreter is not. On a Mac where another account owns `/opt/homebrew` or
  `/usr/local/bin`, that account can choose which `node` runs. The system folders come first on that `PATH`, so
  nothing in those folders can stand in for a system tool such as `security`.
- Claude Code itself. With auto-refresh on, QuotaRing runs the Claude Code you installed; what that program does, and
  which hosts it contacts, is up to Claude Code.
- A compromised Anthropic endpoint or TLS trust store.
- You choosing to paste secrets into a public issue. The issue forms warn against it.

**Revoking Keychain access**

Choosing "Always Allow" on the Keychain prompt adds QuotaRing to the access list of Claude Code's Keychain item. That
grant belongs to the item, not to QuotaRing's settings: turning Live mode off does not remove it, and any later
QuotaRing build signed by the same developer can read the item without a prompt. To revoke it, open Keychain Access,
find the "Claude Code-credentials" item (with a custom config directory, the variant named after it) and open it. Under
Access Control, select QuotaRing in the list, remove it with the minus button, and choose Save Changes.

## Why the app is not sandboxed

The macOS App Sandbox would stop QuotaRing from doing its job. It must read `~/.claude.json` and
`~/.claude/projects`, and in Live mode a Keychain item created by another program. Under the sandbox those reads are
impossible, or brittle and dependent on user-granted exceptions that break on updates. QuotaRing is therefore distributed
outside the Mac App Store, with:

- Hardened Runtime enabled;
- Developer ID signing and Apple notarization;
- no third-party runtime dependencies;
- a single network host, fixed in code;
- one optional program to run (Claude Code's `claude`), validated and run with a fixed command, which needs no sandbox
  exception either;
- source that is small enough to audit.

The trade-off is real: an unsandboxed app has the same file access as you. That is why the code is open, the privacy
behavior is documented in the [README](README.md), and the code paths that touch credentials and the network are kept
small and separate (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

## Data handled

| Data | Where it comes from | What QuotaRing does with it |
| --- | --- | --- |
| OAuth access token (Live mode only) | Keychain item `Claude Code-credentials` (or a per-config-directory variant), or an owner-only `.credentials.json` | Read-only, in memory, per poll. Sent only in the `Authorization` header to `api.anthropic.com`. Never stored, logged, refreshed or forwarded. |
| Usage snapshot (percentages, reset times, weekly breakdown, extra-usage flag and percentage, limit metadata) | `cachedUsageUtilization` in `~/.claude.json`, or the Live endpoint | Shown in the UI. The last good snapshot is saved to `~/Library/Application Support/QuotaRing/last-snapshot.json` (folder mode 700, file mode 600): the percentages and reset times, the weekly breakdown, the extra-usage flag and percentage (money amounts are stripped), limit metadata (kind, group, scope name, severity, active flag), when it was fetched and from which source, and the absolute path of the Claude config directory it belongs to. Never tokens. Deleted when the config directory changes or the cache belongs to another account. |
| Account id | `oauthAccount.accountUuid` and the account id of the cache entry, both in `~/.claude.json` | Compared once per read to detect a cache from another account, then dropped. Never stored, logged or sent. |
| Rest of `~/.claude.json` | Same file | Discarded immediately. Never logged, stored or sent. |
| Transcript metadata | `~/.claude/projects/**/*.jsonl` | Timestamp, model, token counts, project folder name, message id, kept in memory only and dropped after 8 days. Message text is not retained. |
| Output of `claude -p "/usage"` (auto-refresh only) | The `claude` process QuotaRing starts | At most 256 KB, read in memory, checked for the result fields and for any sign of a model request, then dropped. Never logged, stored or sent. The usage numbers themselves are read afterwards from Claude Code's cache, as always. |
| Preferences | Settings window | UserDefaults, non-sensitive values only (including which notification thresholds were already announced for the current window, the auto-refresh consent, and the path of a `claude` tool you chose). |

## Verifying a release

Releases publish `SHA256SUMS` and a GitHub build-provenance attestation next to the DMG and zip. The exact commands
are in the README under [Verify your download](README.md#verify-your-download); they are kept in one place so they
cannot drift.

If any check fails, do not run the app, and please report it using the process above.
