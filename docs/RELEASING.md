# Releasing QuotaRing

This is the owner's checklist for publishing a signed, notarized build. It
assumes an individual Apple Developer Program membership where you are the
Account Holder, and the repository `BartugKaan/QuotaRing`.

Pushing a version tag such as `v0.1.0` starts the **Release** workflow
(`.github/workflows/release.yml`). After you approve it, it:

1. checks the tag, that the tagged commit is on `main`, that the repository is
   public, that no release for the tag exists yet, and that all secrets are set
   (each of these fails within seconds instead of after the long build);
2. installs the pinned XcodeGen (see "Updating the pinned XcodeGen" below),
   generates the Xcode project and checks that the tag equals `MARKETING_VERSION`
   in `project.yml`;
3. imports your Developer ID certificate into a temporary keychain;
4. archives and exports the app with Developer ID signing and the Hardened Runtime;
5. notarizes the app with Apple (`notarytool`) and staples the ticket;
6. builds and signs `QuotaRing-<version>.dmg`, notarizes it and staples it;
7. builds `QuotaRing-<version>.zip` from the stapled app and writes `SHA256SUMS`;
8. verifies signatures, stapling and Gatekeeper acceptance;
9. creates a GitHub build provenance attestation for the DMG and the zip;
10. creates a **draft** GitHub release with the three files.

Nothing is public until you press **Publish release** on the draft.

## One-time setup

Do this once, before the first release. Keep every file you create here out of
the repository (`*.p12` and `*.p8` are in `.gitignore`).

### 0. Repository prerequisites

- The repository must be **public** before the first release. Build provenance
  attestations (and CodeQL results) are not available for private repositories
  on GitHub Free/Pro/Team. While the repository is private the CodeQL job is
  skipped on purpose, and the release workflow stops at its first step with an
  explanatory error.
- Merge the work to `main`. The release workflow refuses tags that are not on
  `main`.

### 1. Create the Developer ID Application certificate

Only the Account Holder can create Developer ID certificates. You need the
**Developer ID Application** type (not "Apple Development", "Apple Distribution"
or "Developer ID Installer").

Option A, in Xcode (simplest):

1. Xcode > Settings > Accounts, select your Apple ID and your team.
2. Click **Manage Certificates...**, click **+** and choose
   **Developer ID Application**.

Option B, on the website:

1. Keychain Access > Certificate Assistant > **Request a Certificate From a
   Certificate Authority...**, enter your email and name, choose **Saved to
   disk**.
2. developer.apple.com > Account > Certificates, IDs & Profiles > Certificates >
   **+** > **Developer ID Application**, choose the **G2 Sub-CA**, upload the
   request file and download the certificate.
3. Double-click the downloaded `.cer` to add it to your login keychain.

Either way, the certificate and its private key now live in your **login**
keychain as "Developer ID Application: Your Name (TEAMID)".

### 2. Export the certificate as a .p12 and encode it

1. Keychain Access > login keychain > **My Certificates**. Find the
   "Developer ID Application" entry; expand it and check that a private key sits
   under it (without the key the export is useless).
2. Right-click the certificate > **Export...** > format **Personal Information
   Exchange (.p12)**. Save it somewhere temporary.
3. Choose a strong, random export password and store it in your password
   manager. This is `DEVELOPER_ID_P12_PASSWORD`.
4. Encode it and copy the result to the clipboard:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

   That text is `DEVELOPER_ID_P12_BASE64`.
5. After you have stored both values as secrets (step 5 below), delete the
   `.p12` or keep it only in your password manager.

### 3. Create an App Store Connect API key for notarization

1. appstoreconnect.apple.com > **Users and Access** > **Integrations** >
   **App Store Connect API** > **Team Keys**. (The first time, the Account
   Holder may need to request API access.)
2. Click **+**, name it "QuotaRing notarization", set **Access** to
   **Developer**, and generate it.
3. Download `AuthKey_<KEYID>.p8` right away; Apple lets you download it once.
4. Note the **Key ID** (shown in the key list) and the **Issuer ID** (a UUID at
   the top of the page).
5. Encode the key:

   ```sh
   base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

   That text is `ASC_KEY_P8_BASE64`.

### 4. Find your Team ID

developer.apple.com > Account > **Membership details** > **Team ID** (ten
characters, letters and digits). This is `APPLE_TEAM_ID`.

### 5. Create the `release` environment and add the secrets

1. GitHub > the repository > **Settings** > **Environments** > **New
   environment**, name it exactly `release`.
2. Tick **Required reviewers** and add yourself (`@BartugKaan`). Leave "Prevent
   self-review" off, otherwise you could not approve your own release.
3. Under **Deployment branches and tags** choose **Selected branches and tags**
   and add a tag rule `v*`.
4. Under **Environment secrets** add all six secrets (environment secrets, not
   repository secrets, so only an approved release run can read them):

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_P12_BASE64` | Base64 of the exported `.p12` (step 2) |
   | `DEVELOPER_ID_P12_PASSWORD` | The password you set on the `.p12` (step 2) |
   | `APPLE_TEAM_ID` | Team ID (step 4) |
   | `ASC_KEY_ID` | Key ID of the App Store Connect API key (step 3) |
   | `ASC_ISSUER_ID` | Issuer ID of the App Store Connect API key (step 3) |
   | `ASC_KEY_P8_BASE64` | Base64 of `AuthKey_<KEYID>.p8` (step 3) |

### 6. Protect release tags (required)

Do not skip this and do it **before** the first tag. A tag push is what starts
the signing workflow, so who may create, move or delete `v*` tags decides who
can ask for your certificate to be used.

1. GitHub > the repository > **Settings** > **Rules** > **Rulesets** > **New
   ruleset** > **New tag ruleset**.
2. Name it "Protect release tags" and set **Enforcement status** to **Active**.
3. Under **Bypass list** click **Add bypass** and add the **Repository admin**
   role (bypass mode **Always**). This is what still lets you, as the owner,
   create the tag and delete it again when a release has to be redone.
4. Under **Target tags** choose **Add target** > **Include by pattern** and enter
   `v*`.
5. Under **Rules** tick **Restrict creations**, **Restrict updates** and
   **Restrict deletions** (and **Block force pushes** if it is offered).
6. Click **Create**.

Afterwards, test it once: a `v*` tag pushed by anyone without the bypass should
be rejected. Together with the required reviewer and the `v*` rule on the
`release` environment (step 5), a stolen or compromised collaborator account
cannot start a signed release by itself.

## Cutting a release (example: v0.1.0)

1. Make sure CI (and, once the repository is public, CodeQL) is green on `main`.
2. In a branch, bump the version and the changelog:
   - set `MARKETING_VERSION` in `project.yml` to `0.1.0` (and bump
     `CURRENT_PROJECT_VERSION`, the build number, if `project.yml` defines one);
   - in `CHANGELOG.md` move the `Unreleased` entries under
     `## [0.1.0] - YYYY-MM-DD`. The workflow copies that section into the draft
     release notes.
3. Open a pull request, get it green and merge it to `main`.
4. Tag the merge commit and push the tag:

   ```sh
   git checkout main && git pull
   git tag -a v0.1.0 -m "QuotaRing 0.1.0"
   git push origin v0.1.0
   ```

5. GitHub > **Actions** > the **Release** run. **Before approving, confirm that
   the commit SHA of the run equals the tip of `main`.** The workflow only checks
   that the tagged commit is somewhere on `main`, so an older commit would pass
   its check; you are the one who checks that this is the commit you meant to
   ship:

   ```sh
   git ls-remote origin refs/heads/main     # tip of main on GitHub
   git rev-parse v0.1.0^{commit}            # commit the tag points at
   ```

   Both must print the same SHA, and it must be the commit shown at the top of the
   run. If it differs, click **Reject** instead, and find out why. If it matches,
   open **Review deployments**, tick `release` and click **Approve and deploy**.
6. Wait. Archiving takes a few minutes; each of the two notarization rounds
   usually takes 2 to 15 minutes but Apple can be slower. Each round waits at
   most 45 minutes by default and the whole job is cut off after 150 minutes.
   **The very first notarization on a new developer account can take much longer
   than usual (hours, in bad cases).** To avoid your first release being that
   first submission, notarize any small signed test app once beforehand with
   `xcrun notarytool submit`. If you expect a slow day, set a variable named
   `NOTARY_TIMEOUT` (for example `90m`) under the `release` environment's
   **Environment variables**, and raise `timeout-minutes` in
   `.github/workflows/release.yml` to match (two rounds plus about 30 minutes
   for the build). The value is a number followed by `s`, `m` or `h`.
7. GitHub > **Releases** now shows a **draft** `QuotaRing 0.1.0` with
   `QuotaRing-0.1.0.dmg`, `QuotaRing-0.1.0.zip` and `SHA256SUMS`.

## Check the draft, then publish

Download the three files from the draft and, in that folder, run:

```sh
shasum -a 256 -c SHA256SUMS
gh attestation verify QuotaRing-0.1.0.dmg --repo BartugKaan/QuotaRing
gh attestation verify QuotaRing-0.1.0.zip --repo BartugKaan/QuotaRing
xcrun stapler validate QuotaRing-0.1.0.dmg
spctl --assess --type open --context context:primary-signature -v QuotaRing-0.1.0.dmg
```

Then do the real-world test on a Mac that has never seen the app, or at least
with a freshly downloaded copy (so it carries the quarantine flag): open the DMG,
drag QuotaRing to Applications and start it. You should get at most the usual
"downloaded from the Internet" confirmation, never "cannot be verified" or
"damaged".

When you are satisfied, edit the notes if you like and press **Publish
release**.

## When something fails

The release job fails early and with a readable message in most cases.

| Message or symptom | Cause and fix |
| --- | --- |
| `Missing secrets in the 'release' environment: ...` | A secret is absent or empty, or it was added as a repository secret instead of an environment secret. |
| `Tag ... must look like v0.1.0` | Only `vMAJOR.MINOR.PATCH` tags are accepted. |
| `Tag ... does not point at a commit on main` | Merge to `main` first and tag the merged commit. |
| `This repository is private. Build provenance attestation needs a public repository` | Make the repository public (Settings > General > Danger Zone), then re-run. |
| `A release for v... already exists; delete the draft or bump the version` | An earlier run left a draft (or you published that version). Delete the draft under Releases, or release the next version number instead. |
| `NOTARY_TIMEOUT '...' must be a number followed by s, m or h` | Fix the `NOTARY_TIMEOUT` environment variable, for example `90m` or `2h`. |
| `Notarization did not succeed (status: unknown ...)` after a long wait | Apple did not answer within `NOTARY_TIMEOUT` (see the note on new accounts above). Re-run the failed job; consider a larger `NOTARY_TIMEOUT`. |
| `XcodeGen ... checksum mismatch` | The download does not match the SHA-256 pinned in `scripts/ci/install-xcodegen.sh`, and nothing was installed. Re-run once. If it fails again, compare the hash with the one shown for that asset on XcodeGen's GitHub release page before you change anything; never just paste in the hash from the error message. |
| `Tag ... does not match MARKETING_VERSION` | Bump `MARKETING_VERSION` in `project.yml`, merge, and re-tag (see below). |
| `DEVELOPER_ID_P12_BASE64 is not valid base64` | Re-create the value with `base64 -i DeveloperID.p12`. |
| `MAC verification failed` while importing | `DEVELOPER_ID_P12_PASSWORD` does not match the password used for the export. |
| `no valid 'Developer ID Application' identity` | Wrong certificate type, expired, or exported without its private key. Export again from **My Certificates**. |
| `does not belong to the team in APPLE_TEAM_ID` | `APPLE_TEAM_ID` is not the team that owns the certificate. |
| Archive, export or DMG signing fails with `errSecInternalComponent`, `User interaction is not allowed`, or "unable to build chain" / "no identity found" right after a successful import | codesign cannot use the private key. `scripts/release/import-cert.sh` imports it non-extractable (`-x`) with only `/usr/bin/codesign` on its access list, so that nothing in the build can export the identity. First check that `security set-key-partition-list` ran without an error in the import step, and re-run the failed job once. If it still fails, try a run with `-T /usr/bin/security` added back to the `security import` call (keep `-x`), and record what was needed in the script's comment. Do not drop `-x`: it is what keeps the key from being copied out of the keychain. |
| `Notarization did not succeed (status: Invalid ...)` | The step prints Apple's log. Typical causes: Hardened Runtime off, an unsigned nested binary, or a missing secure timestamp. |
| `HTTP status code: 401` from `notarytool` | `ASC_KEY_ID`, `ASC_ISSUER_ID` or `ASC_KEY_P8_BASE64` is wrong, or the key was revoked or lacks the Developer role. |
| Attestation step fails | The repository is private (see "Repository prerequisites"), or the job lacks `id-token: write` and `attestations: write`. |
| `gh release create` says the release already exists | Delete the draft (or the release) for that tag and re-run the failed job. |

To retry without code changes, use **Re-run failed jobs** on the run (you will be
asked to approve the deployment again). If you must change code, delete the tag
and tag again after the fix is on `main`:

```sh
git tag -d v0.1.0
git push --delete origin v0.1.0
```

Delete any draft release that was created for that tag before re-tagging.

## Rotating or revoking credentials

- **Certificate:** revoke it at developer.apple.com > Certificates, create a new
  one, export a new `.p12` and update `DEVELOPER_ID_P12_BASE64` and
  `DEVELOPER_ID_P12_PASSWORD`. Developer ID Application certificates are valid
  for five years. Builds that were notarized with a secure timestamp keep working
  after the certificate expires.
- **API key:** revoke it under Users and Access > Integrations in App Store
  Connect and update the three `ASC_*` secrets.
- If you ever suspect a leak, rotate everything, then look through the Actions
  tab for runs you did not start.

## How the secrets are handled

- Secrets are only available to the `release` job after you approve it, and are
  passed only to the steps that need them.
- The certificate goes into a temporary keychain with a random password, which
  is deleted as soon as the disk image is signed (before the attestation and
  release steps) and also if any earlier step fails. The
  decoded `.p12` and `.p8` live in private temp files that are deleted when the
  script exits.
- The private key is imported non-extractable, with only `codesign` on its
  access list, so nothing that runs during the build can export the identity
  while the keychain is unlocked.
- No script prints a secret, and none enables shell tracing.
- Third-party actions are pinned to full commit SHAs; Dependabot proposes updates
  weekly. The workflow itself holds the minimum permissions it needs.
- XcodeGen is not installed with Homebrew. `scripts/ci/install-xcodegen.sh`
  downloads one exact release from the official GitHub releases, refuses to use
  it unless its SHA-256 equals the value written in the script, and only then
  unpacks it. CI and CodeQL use the same script.

## Updating the pinned XcodeGen

Dependabot does not track this pin, so look at
[XcodeGen's releases](https://github.com/yonaskolb/XcodeGen/releases) now and then.
To move to a new version:

1. Download `xcodegen.zip` of that release into an empty folder and compute the
   hash yourself:

   ```sh
   curl -fsSL -o xcodegen.zip \
     https://github.com/yonaskolb/XcodeGen/releases/download/<version>/xcodegen.zip
   shasum -a 256 xcodegen.zip
   ```

2. Put the version in `XCODEGEN_VERSION` and the hash in `XCODEGEN_SHA256` at the
   top of `scripts/ci/install-xcodegen.sh`, in the same commit.
3. Check it locally: `XCODEGEN_INSTALL_DIR=$(mktemp -d) scripts/ci/install-xcodegen.sh`
   must print "SHA-256 verified" and "Installed XcodeGen <version>". Change one
   character of the hash and it must fail with "checksum mismatch".

The script is the single source of truth for the version. `make setup` (local
development) still installs whatever version Homebrew has.

## The Xcode 16.4 job

The README promises "Xcode 16.4 or later", so the CI workflow has a job that
selects Xcode 16.4 exactly (`XCODE_VERSION` in `scripts/ci/select-xcode.sh`) and
runs `make test`, an unsigned `make build` and `make test-app` with it. If GitHub removes Xcode 16.4
from the `macos-15` image, that job fails on purpose instead of testing another
version. Then raise the documented minimum (README, CONTRIBUTING, and the job)
together.
