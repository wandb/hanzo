# Sparkle Setup on GitHub

This repo already has the Sparkle framework wired into the app and the release workflow already produces signed/notarized ZIP and DMG artifacts. The remaining work is to add your Sparkle signing key, publish an appcast, and host that appcast on GitHub Pages.

## URLs used by Hanzo

- Sparkle feed: `https://wandb.github.io/hanzo/appcast.xml`
- GitHub Releases: `https://github.com/wandb/hanzo/releases`

If the repo owner or repo name changes, update `SUFeedURL` in `HanzoCore/Info.plist`.

## One-time setup

### 1. Generate the Sparkle EdDSA keypair

Run this from the repo root:

```sh
./.build/artifacts/sparkle/Sparkle/bin/generate_keys --account hanzo
```

Sparkle will print a `SUPublicEDKey` value. Copy that value into `HanzoCore/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>YOUR_PUBLIC_KEY_HERE</string>
```

The public key is safe to commit.

### 2. Export the private Sparkle key for CI

Export the private key from your login keychain to a temporary file:

```sh
./.build/artifacts/sparkle/Sparkle/bin/generate_keys --account hanzo -x .context/sparkle_private_ed_key.txt
```

Add the file contents as a GitHub Actions repository secret named:

- `SPARKLE_PRIVATE_ED_KEY`

That secret is used by the release workflow to sign `appcast.xml` and the Sparkle update entries.

### 3. Enable GitHub Pages

In GitHub:

1. Open `wandb/hanzo`.
2. Go to `Settings` -> `Pages`.
3. Under `Build and deployment`, choose `GitHub Actions` as the source.

The release workflow deploys a static site containing:

- `appcast.xml`
- Sparkle ZIP archives in `/downloads/`
- release note markdown files in `/downloads/`

### 4. Confirm signing and notarization secrets already exist

Signed Sparkle updates only work if the app release itself is signed and notarized. The release workflow already expects these secrets:

- `MACOS_SIGN_IDENTITY`
- `MACOS_SIGNING_CERT_B64`
- `MACOS_SIGNING_CERT_PASSWORD`
- `MACOS_KEYCHAIN_PASSWORD`
- `NOTARY_API_KEY_ID`
- `NOTARY_API_ISSUER_ID`
- `NOTARY_API_PRIVATE_KEY_B64`

## Release flow

### 1. Prepare the version

```sh
./scripts/version.sh set --version 1.0.0 --build-number 1
git commit -am "Release 1.0.0"
git tag v1.0.0
git push origin main --tags
```

Match the Git tag to `CFBundleShortVersionString`. Sparkle compares `CFBundleVersion`, so keep that incrementing on every release.

### 2. What GitHub Actions does

On a `v*` tag, `.github/workflows/release.yml` now does all of this:

1. Builds signed and notarized release artifacts.
2. Publishes the ZIP, DMG, and checksum to GitHub Releases.
3. Downloads the newest release ZIPs from GitHub Releases.
4. Runs Sparkle `generate_appcast` against those ZIPs.
5. Deploys `appcast.xml` and the mirrored Sparkle ZIPs to GitHub Pages.

The Pages site is built by:

```sh
./scripts/build-sparkle-appcast-site.sh
```

By default the script mirrors the newest 6 published ZIP releases and keeps the newest 3 versions in the generated appcast.

## First-release checklist

1. Merge the `SUPublicEDKey` change to `main`.
2. Add the `SPARKLE_PRIVATE_ED_KEY` GitHub secret.
3. Enable GitHub Pages with `GitHub Actions`.
4. Push the first signed `v*` tag.
5. Wait for the release workflow to finish.
6. Open `https://wandb.github.io/hanzo/appcast.xml` and confirm it loads.
7. Download the released app, launch it, and use `Check for Updates...`.

## Local dry run

After you have exported the private Sparkle key and authenticated `gh`, you can build the Pages site locally:

```sh
export GH_TOKEN="$(gh auth token)"
export SPARKLE_PRIVATE_ED_KEY="$(cat .context/sparkle_private_ed_key.txt)"
./scripts/build-sparkle-appcast-site.sh \
  --repo wandb/hanzo \
  --site-url https://wandb.github.io/hanzo
```

The generated static site will be written to `dist/sparkle-site/`.

## Notes

- The Sparkle update feed uses GitHub Pages because Hanzo does not have a dedicated updates host yet.
- Manual downloads still come from GitHub Releases.
- When Hanzo eventually moves to a custom updates domain, ship one release that changes `SUFeedURL` so existing installs learn the new feed location.
