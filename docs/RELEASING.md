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
./scripts/release.sh --version 1.0.0 --build-number 1 --unsigned
```

Fast unsigned repeat build:

```sh
./scripts/release-unsigned.sh
```

Signed + notarized (actual local workflow):

```sh
./scripts/version.sh bump-build
./scripts/release.sh
```

## Versioning workflow

`release.sh` already supports `--version` and `--build-number`, and if those flags are omitted it reads both values from `HanzoCore/Info.plist`.

Use `./scripts/version.sh` to track and bump versions in `Info.plist`:

```sh
./scripts/version.sh show
./scripts/version.sh bump-build
./scripts/version.sh bump-patch
./scripts/version.sh set --version 1.2.0 --build-number 1
```

Typical local distribution loop:

```sh
./scripts/version.sh bump-build
./scripts/release-unsigned.sh
```

For GitHub tag releases, keep tags aligned with `CFBundleShortVersionString` (e.g. tag `v1.2.0` when app version is `1.2.0`).

## GitHub Actions release workflow

Workflow file: `.github/workflows/release.yml`

- `workflow_dispatch` supports unsigned test builds.
- Tag pushes (`v*`) build signed/notarized artifacts and publish a GitHub Release.
- Tag pushes read `CFBundleShortVersionString` and `CFBundleVersion` from `HanzoCore/Info.plist`; the tag must match the plist version.

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
