# Releasing Hanzo

This project ships as a direct-download macOS app (Apple Silicon only), with Sparkle for auto-updates.

## Release artifacts

`./scripts/release.sh` builds:

- `Hanzo-<version>-<build>.zip` (for Sparkle updates)
- `Hanzo-<version>-<build>.dmg` (for manual installs)
- `Hanzo-<version>-<build>.sha256` (checksums)

By design, models are still first-run downloads. Release artifacts do not embed model files.

## Local release commands

Unsigned dry run:

```sh
./scripts/release.sh --version 1.0.0 --build-number <next-build-number> --unsigned
```

Fast unsigned repeat build:

```sh
./scripts/release-unsigned.sh
```

Most local release validation on a machine with signing configured:

```sh
./scripts/release.sh --skip-notarize
```

Occasional local full notarization:

```sh
./scripts/release.sh
```

## Versioning workflow

`release.sh` already supports `--version` and `--build-number`, and if those flags are omitted it reads both values from `HanzoCore/Info.plist`.

Use `./scripts/version.sh` to track and bump versions in `Info.plist`:

```sh
./scripts/version.sh show
./scripts/version.sh bump-build
./scripts/version.sh bump-patch
./scripts/version.sh set --version 1.2.0 --build-number <next-build-number>
```

`bump-build`, `bump-patch`, `bump-minor`, and `bump-major` all increment `CFBundleVersion` so build numbers stay monotonic for Sparkle.

### Sparkle build number rule (important)

Sparkle compares `CFBundleVersion` for update eligibility. `CFBundleVersion` must be monotonically increasing across all public releases, even when `CFBundleShortVersionString` changes.

- Do not reset `CFBundleVersion` to `1` for a new patch/minor/major version.
- Choose a build number greater than the last shipped build number.
- Example: if `1.0.2` shipped with `CFBundleVersion=4`, then `1.0.3` must use `CFBundleVersion=5` or higher.

Recommended release prep commands:

```sh
./scripts/version.sh show
./scripts/version.sh set --version 1.0.3 --build-number 5
./scripts/changelog.sh prepare --version 1.0.3
```

Typical local packaging loop when you want signed artifacts without notarization:

```sh
./scripts/version.sh bump-build
./scripts/release.sh --skip-notarize
```

For GitHub tag releases, keep tags aligned with `CFBundleShortVersionString` (e.g. tag `v1.2.0` when app version is `1.2.0`) and ensure `CFBundleVersion` is higher than the previous shipped release.

## Changelog workflow

Release notes are drafted automatically from merged PRs on `main` via Release Drafter, but the committed `CHANGELOG.md` is the source of truth for shipped notes.

Recommended release prep sequence:

```sh
./scripts/version.sh set --version 1.0.3 --build-number 5
./scripts/changelog.sh prepare --version 1.0.3
```

After running `prepare`:

- review and edit `CHANGELOG.md`
- commit the curated notes before creating the `v*` tag
- keep the changelog entry non-empty, because tag releases fail if the matching version entry is missing

`./scripts/changelog.sh prepare` fetches the current GitHub draft release body by default, so local release prep requires `gh auth login`. Use `--body-file` if you want to seed an entry from a local markdown file instead.

## Recommended operating model

- Use `./scripts/dev-run.sh` for normal app development.
- Use `./scripts/release.sh --skip-notarize` for most local packaging/signing checks.
- Use `./scripts/release.sh --unsigned` or `./scripts/release-unsigned.sh` on machines that do not have Developer ID signing configured.
- Use `./scripts/release.sh` only when you need a full local notarization sanity check.
- Treat the GitHub tag workflow as the canonical public release path. The DMG and ZIP published from GitHub Releases are the official shipped artifacts.

## App Store Connect API key setup

Hanzo's release automation is designed around an App Store Connect API key for notarization, not a personal Apple ID login. Use a Team API key so local notarization and GitHub Actions share the same auth model.

### 1. Create the Team API key in App Store Connect

As of March 30, 2026, the flow in App Store Connect is:

1. Open `https://appstoreconnect.apple.com/`.
2. Go to `Users and Access`.
3. Open the `Integrations` tab.
4. In `App Store Connect API`, request access if your team has never enabled it before.
5. Open `Team Keys`.
6. Click `Generate API Key`.
7. Enter a name like `Hanzo Release CI`.
8. Choose an access level that allows notarization for your team.
9. Download the generated `AuthKey_<KEY_ID>.p8` file and store it securely.
10. Copy the displayed `Key ID` and `Issuer ID`.

Notes:

- The `.p8` private key is only downloadable once.
- You need an Account Holder, Admin, or equivalent App Store Connect permission that allows generating API keys.

### 2. Configure the local notarytool profile with that API key

From the repo root:

```sh
./scripts/configure-notarytool-profile.sh \
  --profile hanzo-notary \
  --key-id YOUR_KEY_ID \
  --issuer YOUR_ISSUER_ID \
  --key-file ~/Downloads/AuthKey_YOUR_KEY_ID.p8
```

That stores a validated `notarytool` keychain profile that `./scripts/release.sh` can reuse locally.

If you want that profile to be the default for future shells:

```sh
export HANZO_NOTARY_PROFILE=hanzo-notary
```

### 3. Add the same API key to GitHub Actions

The release workflow expects these repository secrets:

- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`
- `NOTARY_API_PRIVATE_KEY_B64`

Example commands:

```sh
gh secret set NOTARY_API_KEY_ID --body "YOUR_KEY_ID"
gh secret set NOTARY_API_ISSUER_ID --body "YOUR_ISSUER_ID"
base64 < ~/Downloads/AuthKey_YOUR_KEY_ID.p8 | tr -d '\n' | \
  gh secret set NOTARY_API_PRIVATE_KEY_B64
```

## GitHub Actions release workflow

Workflow file: `.github/workflows/release.yml`

- `workflow_dispatch` supports unsigned test builds.
- Tag pushes (`v*`) build signed/notarized artifacts and publish a GitHub Release.
- Tag pushes read `CFBundleShortVersionString` and `CFBundleVersion` from `HanzoCore/Info.plist`; the tag must match the plist version.
- Tag pushes publish the matching `CHANGELOG.md` entry as the GitHub release body.

Required repository secrets for signed releases:

- `MACOS_SIGN_IDENTITY`
- `MACOS_SIGNING_CERT_B64` (base64 `.p12`)
- `MACOS_SIGNING_CERT_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`
- `NOTARY_API_PRIVATE_KEY_B64` (base64 `.p8`)

## Sparkle auto-update setup

The app includes Sparkle and will show `Check for Updates...` only after `SUPublicEDKey` is configured.

Hanzo is configured to look for its appcast at:

`https://wandb.github.io/hanzo/appcast.xml`

GitHub-backed Sparkle rollout is documented in `docs/SPARKLE_SETUP.md`.

In short:

1. Generate Sparkle EdDSA keys (`generate_keys`) and add `SUPublicEDKey` to `HanzoCore/Info.plist`.
2. Export the private EdDSA key and store it as the GitHub Actions secret `SPARKLE_PRIVATE_ED_KEY`.
3. Enable GitHub Pages for this repo with `GitHub Actions` as the publishing source.
4. Push a signed tag release (`v*`); the release workflow publishes artifacts to GitHub Releases, builds `appcast.xml`, and deploys the Sparkle feed to GitHub Pages.
