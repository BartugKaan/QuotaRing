## Summary

<!-- What does this change and why? Link related issues with "Fixes #123". -->

## Type of change

<!-- Match your Conventional Commit type: feat, fix, docs, test, refactor, chore, ci, ... -->

-

## Privacy and security impact

<!-- QuotaRing's value is that it is easy to audit. Answer each line; "no" is a fine answer. -->

- Reads any new file, folder, or Keychain item: <!-- yes/no, which -->
- Sends data anywhere (new host, new request, new header): <!-- yes/no, which -->
- Stores anything new on disk or in UserDefaults: <!-- yes/no, what -->
- Touches token handling, logging, or Claude Code's files: <!-- yes/no -->

## Checklist

- [ ] The change is focused and the commits follow [Conventional Commits](https://www.conventionalcommits.org/)
- [ ] `make test-all` passes and new logic has tests (Swift Testing)
- [ ] `make lint` passes (run `make format` to fix formatting)
- [ ] `make build` succeeds
- [ ] No tokens, credentials, or real usage data in code, fixtures, logs, or screenshots
- [ ] No new network hosts, telemetry, or third-party runtime dependencies
- [ ] User-facing strings are localized (`String(localized:)` / `LocalizedStringKey`)
- [ ] Docs updated if behavior changed (README, `docs/ARCHITECTURE.md`, `SECURITY.md`)
- [ ] `CHANGELOG.md` updated under `[Unreleased]` for user-visible changes

## Screenshots

<!-- For UI changes. Use `make demo` so no real usage data appears. -->
