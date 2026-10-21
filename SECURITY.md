# Security Policy

QuotaRing is a small app that can, in its opt-in Live mode, handle a sensitive secret (Claude Code's OAuth token). Security
reports are taken seriously and are very welcome.

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

This is a volunteer-run project, so these are targets, not guarantees:

| Step | Target |
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
- Crashes, hangs or unbounded resource use triggered by malformed, hostile or huge `~/.claude.json`, transcript or API
  response data.
- Weaknesses in the build, signing, notarization or release pipeline (for example unpinned actions, leaked secrets,
  tampered artifacts).
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
3. The integrity of the app you run.

**Controls**

| Risk | Control |
| --- | --- |
| Token leaks to disk or logs | The token is read from the Keychain on every poll, wrapped in a `Secret` type whose description, debug description and reflection are redacted and which is not `Codable`, used for one request, then dropped. It is never put in UserDefaults, files, logs, crash reports or the pasteboard. Logging uses `os.Logger` with privacy annotations and never includes token-derived data. |
| Token sent to the wrong place | The endpoint is a compile-time constant (`https://api.anthropic.com/api/oauth/usage`), not a setting, so configuration or a hostile file cannot redirect it. HTTPS only, with App Transport Security defaults. |
| Cross-request leakage | Requests use an ephemeral `URLSession`: no cookies, no URL cache, no credential storage. |
| Breaking the user's Claude Code login | QuotaRing never refreshes tokens (refresh tokens are single-use) and never launches the `claude` CLI. An expired token is not sent anywhere. |
| Reading more than necessary | From `~/.claude.json` only the `cachedUsageUtilization` key is kept; the rest is dropped immediately. Transcripts are reduced to timestamp, model, token counts, project folder name and message id. A credentials file is accepted only if it is a regular file owned by you and not group or world readable. Nothing is read from the Keychain before you opt in. |
| Damaging Claude's files | QuotaRing only reads them. It has no code path that writes `~/.claude.json`, `~/.claude/**` or Keychain items. |
| Hostile or corrupted input | Defensive parsing that never trusts shape or size: files over 50 MB and transcript lines over 10 MB are skipped, truncated or malformed JSON keeps the previous snapshot, unknown keys are ignored. The decoder tolerates bad entries rather than crashing. |
| Supply chain (runtime) | No third-party runtime dependencies. The attack surface is Apple's SDKs and this repository. |
| Supply chain (build and release) | CI uses least-privilege `permissions` and pins every GitHub Action to a commit SHA, with Dependabot keeping them current. Releases are built in CI on a protected `release` environment, signed with a Developer ID certificate, notarized by Apple, published with `SHA256SUMS` and a GitHub build-provenance attestation. CodeQL scans the Swift code. |
| Telemetry | None: no analytics, crash reporting SDKs or update pings. |

**Not defended against**

- Malware already running as you. It can read the same files, and it can request the same Keychain item.
- A compromised Anthropic endpoint or TLS trust store.
- You choosing to paste secrets into a public issue. The issue forms warn against it.

## Why the app is not sandboxed

The macOS App Sandbox would stop QuotaRing from doing its job. It must read `~/.claude.json` and
`~/.claude/projects`, and in Live mode a Keychain item created by another program. Under the sandbox those reads are
impossible, or brittle and dependent on user-granted exceptions that break on updates. QuotaRing is therefore distributed
outside the Mac App Store, with:

- Hardened Runtime enabled;
- Developer ID signing and Apple notarization;
- no third-party runtime dependencies;
- a single network host, fixed in code;
- source that is small enough to audit.

The trade-off is real: an unsandboxed app has the same file access as you. That is why the code is open, the privacy
behavior is documented in the [README](README.md), and the code paths that touch credentials and the network are kept
small and separate (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

## Data handled

| Data | Where it comes from | What QuotaRing does with it |
| --- | --- | --- |
| OAuth access token (Live mode only) | Keychain item `Claude Code-credentials` (or a per-config-directory variant), or an owner-only `.credentials.json` | Read-only, in memory, per poll. Sent only in the `Authorization` header to `api.anthropic.com`. Never stored, logged, refreshed or forwarded. |
| Usage snapshot (percentages, reset times) | `cachedUsageUtilization` in `~/.claude.json`, or the Live endpoint | Shown in the UI. The last good snapshot is saved to `~/Library/Application Support/QuotaRing/last-snapshot.json` (no secrets). |
| Rest of `~/.claude.json` | Same file | Discarded immediately. Never logged, stored or sent. |
| Transcript metadata | `~/.claude/projects/**/*.jsonl` | Timestamp, model, token counts, project folder name, message id, kept in memory only. Message text is not retained. |
| Preferences | Settings window | UserDefaults, non-sensitive values only. |

## Verifying a release

```sh
grep 'QuotaRing.dmg$' SHA256SUMS | shasum -a 256 -c
gh attestation verify QuotaRing.dmg --repo BartugKaan/QuotaRing
spctl --assess --type execute --verbose=2 /Applications/QuotaRing.app
```

If any of these fail, do not run the app, and please report it using the process above.
