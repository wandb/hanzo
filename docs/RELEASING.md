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

Signed + notarized:

```sh
./scripts/release.sh \
  --version 1.0.0 \
  --build-number 1 \
  --sign-identity "Developer ID Application: Your Name (TEAMID)" \
  --notary-profile hanzo-notary
```

## GitHub Actions release workflow

Workflow file: `.github/workflows/release.yml`

- `workflow_dispatch` supports unsigned test builds.
- Tag pushes (`v*`) build signed/notarized artifacts and publish a GitHub Release.

Required repository secrets for signed releases:

- `MACOS_SIGN_IDENTITY`
- `MACOS_SIGNING_CERT_B64` (base64 `.p12`)
- `MACOS_SIGNING_CERT_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`
- `NOTARY_API_PRIVATE_KEY_B64` (base64 `.p8`)

## Sparkle auto-update setup

The app now includes Sparkle and shows `Check for Updates...` in the menu.

Remaining production setup:

1. Choose and host an appcast URL (recommended: `https://updates.hanzo.ai/appcast.xml`).
2. Generate Sparkle EdDSA keys (`generate_keys`) and add `SUPublicEDKey` to `HanzoCore/Info.plist`.
3. Generate/update `appcast.xml` from each signed release (Sparkle `generate_appcast`).
4. Host `appcast.xml` plus release artifacts over HTTPS.

Best practice for hosting:

- Keep binaries in GitHub Releases initially.
- Host `appcast.xml` on a stable custom domain (`updates.hanzo.ai`) so update URLs remain stable if hosting changes later.
