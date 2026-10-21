# QuotaRing

A tiny, auditable menu bar meter for your Claude subscription limits.

QuotaRing puts a ring in your macOS menu bar that shows how much of your rolling 5-hour Claude limit is left. Click it
for weekly limits, the reset time and a breakdown of where your tokens went.

![QuotaRing popover showing the 5-hour session ring, weekly limits and local activity](docs/images/screenshot.png)

It exists because menu bar usage meters are easy to build and hard to trust. The goal here is the opposite: a small,
open-source app whose behavior you can read in an afternoon. Everything it reads, sends and stores is listed in
[How it works and privacy](#how-it-works-and-privacy) below.

## Features

- **Menu bar ring.** Shows the share of the 5-hour session limit that remains, with optional percentage text. The ring
  turns orange at 20% remaining or less and red at 5% or less.
- **Popover.** One click shows:
  - the session limit with a reset countdown and clock time;
  - weekly limits (all models, plus any model-specific limits) and extra usage when it is enabled;
  - Anthropic's own "where it went" breakdown for the week, when available;
  - local activity: tokens by model, top projects and a 7-day chart, for the current session, today or the last 7 days.
- **Notifications.** Local notifications when session usage crosses a threshold (default 80% and 95% used), once per
  window. An optional notice when the session resets (off by default).
- **Settings.** Launch at login, refresh interval (3, 5, 10 or 15 minutes), ring shows remaining or used, percentage
  text on or off, notification thresholds, Claude config directory, and the Live mode switch.
- **Token-free by default.** The default mode needs no credentials and makes no network connections.
- **Native and small.** Swift 6, AppKit and SwiftUI, universal binary, no third-party runtime dependencies.
- **Light and dark mode, VoiceOver labels, Reduce Motion.** English and Turkish.

Percentages are **percent used**, exactly as Anthropic reports them (the same numbers as `/usage` in Claude Code). The
ring shows what remains (100 minus used) by default; you can switch it to show what is used.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- A Claude subscription, and Claude Code (the CLI, the desktop app or an IDE integration) so there is data to read

## Install

### From GitHub Releases (recommended)

1. Download `QuotaRing-<version>.dmg` (or `QuotaRing-<version>.zip`) from the
   [Releases](https://github.com/BartugKaan/QuotaRing/releases) page.
2. Open the DMG and drag QuotaRing to Applications, then launch it. It has no Dock icon; look for the ring in the menu
   bar.

Release builds are signed with a Developer ID certificate, **notarized by Apple** and stapled, so Gatekeeper opens them
normally. macOS may show a one-time "downloaded from the Internet" confirmation on first launch. If macOS ever says it
cannot verify the app, do not work around the warning: delete the download and check it using
[Verify your download](#verify-your-download).

#### Verify your download

Optional, recommended if you want to be sure what you run. Each release publishes
`QuotaRing-<version>.dmg`, `QuotaRing-<version>.zip` and a `SHA256SUMS` file. Put the file you downloaded and
`SHA256SUMS` in the same folder, then:

```sh
VERSION=0.1.0   # the version you downloaded

# Compare the file with the published checksums (use .zip instead of .dmg for the zip)
grep "QuotaRing-$VERSION\.dmg\$" SHA256SUMS | shasum -a 256 -c

# Verify GitHub's build provenance attestation (needs the GitHub CLI)
gh attestation verify "QuotaRing-$VERSION.dmg" --repo BartugKaan/QuotaRing

# Check the installed app's signature and notarization
codesign --verify --deep --strict --verbose=2 /Applications/QuotaRing.app
spctl --assess --type execute --verbose=2 /Applications/QuotaRing.app
```

The attestation ties the file to the exact commit and workflow run in this repository that built it.

### Build from source

You need macOS 14+, Xcode 16.4 or later (Swift 6) and [Homebrew](https://brew.sh).

```sh
git clone https://github.com/BartugKaan/QuotaRing.git
cd QuotaRing
make setup   # installs XcodeGen through Homebrew (see Brewfile)
make run     # generates the Xcode project, builds and launches the app
```

Other targets: `make demo` (launch with fixture data), `make test`, `make lint`, `make format`. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full list.

Builds from source are **ad-hoc signed** ("Sign to Run Locally") so anyone can build them without a developer account.
If you build often and use Live mode, macOS may ask again for Keychain access after a rebuild, because the signature
changes. To keep a stable signature, copy [`Configs/Local.xcconfig.example`](Configs/Local.xcconfig.example) to
`Configs/Local.xcconfig` (git-ignored) and put your own team there.

`make demo` runs the app on built-in fixture data. It does not touch the Keychain, the network or your Claude files,
which makes it safe for screenshots and for trying the UI.

## How it works and privacy

QuotaRing reads three things. Two of them are always on and are purely local. The third is opt-in.

| Source | What is read | Needs a token | Leaves your Mac |
| --- | --- | --- | --- |
| **Claude Code's cached usage snapshot** | One key, `cachedUsageUtilization`, from `~/.claude.json` | No | No |
| **Local transcripts** | Token counts from `~/.claude/projects/**/*.jsonl` | No | No |
| **Live endpoint** (opt-in "Live mode") | Claude Code's OAuth token from the Keychain, used for one request | Yes | The token goes to `api.anthropic.com` only |

If you set a custom Claude config directory in Settings, the same files are read from there instead.

### Default mode: nothing leaves your Mac

- **The cache.** Claude Code stores the last usage response it fetched in `~/.claude.json`. That file also holds
  unrelated and potentially sensitive configuration (MCP server definitions, account details). QuotaRing reads the file
  into memory only to find the `cachedUsageUtilization` key, keeps that one value, and drops the rest immediately. The
  rest is never logged, stored or sent anywhere. It checks the file's size and modification time every 30 seconds and
  parses it only when it changed. Files over 50 MB are skipped. QuotaRing **never writes** this file.
- **The transcripts.** Claude Code writes conversation logs to `~/.claude/projects`. QuotaRing parses them to count
  tokens, and keeps only the timestamp, model name, token counts, the project folder name and the message id used to
  avoid double counting. Prompt and response text is not retained. The result stays in memory and is never written to
  disk. Lines over 10 MB are skipped. This works without any consent step because no secret is involved.
- **No network.** In this mode the app makes no network connections at all.

The detail view always says where the numbers came from and how old they are, for example "Claude Code · 3 min ago".

### Live mode: opt-in, one host

Live mode asks Anthropic for fresh numbers instead of waiting for Claude Code to update its cache. It is **off by
default**. The first-run screen explains exactly what happens before anything is read, and you can turn it off again in
Settings at any time.

When enabled:

- QuotaRing reads Claude Code's OAuth token **read-only** from the macOS Keychain (the `Claude Code-credentials` item,
  or the variant Claude Code names after a custom config directory). If neither has a usable token, it also checks
  `.credentials.json` in your Claude config directory, but only when that file is owned by you and not readable by
  others. macOS may ask you to allow Keychain access; that prompt comes from the OS.
- The token is **re-read on every poll** and held in memory only for the length of one request. It is never cached
  between polls, written to disk, put in preferences, logged or copied to the pasteboard.
- It makes a single HTTPS `GET` to `https://api.anthropic.com/api/oauth/usage`. The URL is a compile-time constant and
  is not configurable. The request carries four headers: `Authorization: Bearer <token>`,
  `anthropic-beta: oauth-2025-04-20`, `Accept: application/json` and
  `User-Agent: QuotaRing/<version> (+https://github.com/BartugKaan/QuotaRing)`. No body, no cookies. QuotaRing
  identifies itself honestly and does not pretend to be Claude Code.
- The request uses an ephemeral `URLSession`: no cookie storage, no URL cache, no stored credentials.
- Automatic polls are sent only when Live mode is on, the cached snapshot is older than your refresh interval, and
  the token has not expired. Pressing Refresh in the popover while Live mode is on also makes one request, at most
  once every 60 seconds. An expired token is never sent, not even on a manual refresh; QuotaRing falls back to the
  cache and shows a short hint.
- **QuotaRing never refreshes the token.** Refresh tokens are single-use, so a third-party refresh could sign you out
  of Claude Code. When the token has expired, QuotaRing waits until Claude Code renews it.

### What it never does

- Write, modify or delete anything in `~/.claude.json`, `~/.claude/` or the Keychain.
- Launch the `claude` command-line tool.
- Contact any host other than `api.anthropic.com`.
- Include telemetry, analytics, crash reporting or update checks. Check the Releases page for new versions yourself.
- Use third-party libraries at runtime. The only dependencies are Apple's SDKs.
- Use web cookies, claude.ai sessions or scraping.

### What it stores

- `~/Library/Application Support/QuotaRing/last-snapshot.json`: the last good usage snapshot (percentages and reset
  times only), so the ring is meaningful right after launch. It contains no secrets.
- Your preferences, in UserDefaults (non-sensitive values only).

To remove everything, quit the app, delete it, and delete `~/Library/Application Support/QuotaRing`. Preferences can be
cleared with `defaults delete io.github.bartugkaan.QuotaRing`.

### Audit it yourself

The code is small on purpose. The parts that matter for trust live in `Core/Sources/QuotaRingCore`:

- `Cache/` reads the one cache key.
- `Credentials/` is the only code that touches the Keychain or a credentials file.
- `Network/` is the only code that performs requests; the endpoint is a constant there.
- `Transcripts/` scans local logs.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) maps the rest. You can also watch the app with a network monitor such as
LuLu or Little Snitch: in default mode you should see no connections, and in Live mode only `api.anthropic.com`.

### A note on Anthropic's terms

Anthropic's Claude Code legal page says developers "may not collect, store, or intermediate Claude.ai credentials or
session tokens". QuotaRing's Live mode reads **your own** token on **your own** Mac, keeps it in memory, and uses it
only to ask Anthropic for **your own** usage, the same request Claude Code's `/usage` command makes. It never stores,
logs or forwards the token. That is our reading of the line, and we are not Anthropic's lawyers; the policy could be
interpreted differently or change. This is why Live mode is opt-in and why the default mode needs no credentials at all.
If you are not comfortable with it, leave Live mode off. QuotaRing keeps working from Claude Code's cache.

### The usage endpoint is undocumented

`/api/oauth/usage` is not a documented public API. It is the endpoint Claude Code uses for `/usage`, and it can change
or break without notice. It is also known to rate-limit aggressively (HTTP 429), sometimes without a `Retry-After`
header. QuotaRing therefore polls gently (every 5 minutes by default, with jitter and back-off), decodes responses
defensively, never crashes on unexpected data, and keeps showing the last good numbers with their age. The same goes
for the cache and transcript formats, which are internal to Claude Code. If any of them changes, QuotaRing degrades to
whatever it can still read.

## FAQ

**The numbers look stale. Why?**
In default mode QuotaRing shows what Claude Code last wrote to its cache; it does not fetch anything itself. Open Claude
Code or run `/usage` there, and QuotaRing picks up the new snapshot within about 30 seconds (the refresh button in the
popover re-reads the cache immediately). The popover footer shows the source and age of what you are looking at. If you
want QuotaRing to fetch on its own, enable Live mode in Settings.

**Live mode says my login expired, but Claude works fine.**
If you mostly use the Claude desktop app, it manages its own sign-in, so the token Claude Code keeps in the Keychain can
be weeks out of date. QuotaRing does not call the API with an expired token and does not refresh it (that could sign
you out of Claude Code). It falls back to the cache and says so. Running `claude` once renews the Keychain token.

**Why does the ring show remaining, but Claude shows "used"?**
Anthropic reports percent used, and so does QuotaRing's data. The ring shows the remainder (100 minus used) so a full
ring means a full allowance. Settings has a switch to show used instead.

**Does it include claude.ai chats or other devices?**
The session and weekly percentages, and the "where it went" breakdown, come from Anthropic and cover your whole account.
The local activity section (tokens by model and project) only counts Claude Code transcripts on this Mac. It does not
include claude.ai chats or other computers, and the numbers are approximate.

**Why is the app not sandboxed?**
QuotaRing must read `~/.claude.json`, `~/.claude/projects` and, in Live mode, a Keychain item created by another
program. The macOS App Sandbox makes that impossible or brittle, so the app is distributed outside the Mac App Store
with Hardened Runtime and notarization instead. The trade-off is that the app has the same file access as you do, which
is why it is built to be read and checked. See [SECURITY.md](SECURITY.md) for the threat model.

**Does it show API or Console usage?**
No. QuotaRing is for Claude subscription limits only.

**Does QuotaRing use up my limits?**
No. It never sends prompts to a model. Reading the cache and transcripts is entirely local, and the Live mode request
only asks Anthropic for your usage numbers. Because that endpoint is known to rate-limit aggressively, polling defaults
to every 5 minutes and backs off after failures.

**Something is wrong. Where do I report it?**
Open an issue using the bug form, and please do not paste tokens or secrets. For security problems, follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) first, and note the
[Code of Conduct](CODE_OF_CONDUCT.md). Changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE) © 2026 Bartuğ Kaan Çelebi

## Disclaimer

QuotaRing is an independent project and is not affiliated with, endorsed or sponsored by Anthropic. Claude is a
trademark of Anthropic. This project does not use Anthropic or Claude logos.
