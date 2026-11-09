# Releasing

Releases are built only when you start them by hand. Nothing builds on push or pull request, to keep macOS and
Windows runner time for releases. Design notes are in `spec/06` ADR-53.

| Workflow | Starts | Does |
| :-- | :-- | :-- |
| `Release` (`.github/workflows/release.yml`) | Actions > Release > Run workflow | Builds and signs macOS and/or Windows, then creates a **draft** GitHub release with the files |
| `Website` (`.github/workflows/site.yml`) | Actions > Website > Run workflow | Publishes `site/` to GitHub Pages |

## Cutting a release

1. Run **Release** with a version (`1.2.0`, or `1.2.0-beta.1`), the platforms, and whether it is a pre-release.
   The build number is the workflow run number, so every run is higher than the last.
2. When it finishes, open the draft on the Releases page. Check the notes (generated from merged PRs and commits) and
   the files:
   - `NativeScreen.dmg`: signed, notarized and stapled.
   - `appcast.xml`: the Sparkle feed, signed with the update key.
   - `NativeScreen-win-Setup.exe`, `NativeScreen-win-Portable.zip`, and Velopack's update files
     (`NativeScreen-<version>-win-full.nupkg`, `releases.win.json` and friends).
3. Press **Publish**. Only then do the apps see it: both updaters read the latest published, non pre-release release
   (`releases/latest/download/...`). The website's download buttons use the same links.

Both updaters and the download links only look at the **latest** release. A release with one platform hides the other
one's installer and feed until the next release that has both, so publish single-platform releases as pre-releases
(or build both).

If a run fails half way, nothing is published: delete the draft if one was made and run again with the same version.

## One-time setup

All of this goes in **Settings > Secrets and variables > Actions** of the repository.

### macOS signing and notarization

| Name | Kind | Value |
| :-- | :-- | :-- |
| `APPLE_TEAM_ID` | variable | Your team ID (Membership page of the Apple Developer site) |
| `MACOS_CERTIFICATE_P12` | secret | Your **Developer ID Application** certificate and private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | secret | The password you set when exporting the `.p12` |
| `APPLE_API_KEY_P8` | secret | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`), role Developer |
| `APPLE_API_KEY_ID` | secret | That key's ID |
| `APPLE_API_ISSUER_ID` | secret | The issuer ID shown above the key list |

Create the certificate at developer.apple.com > Certificates > **Developer ID Application** if you do not have one. The
API key is made at App Store Connect > Users and Access > Integrations > App Store Connect API.

### Sparkle update key

Sparkle checks every update against an EdDSA key. Make it once on your Mac with Sparkle's `generate_keys` (in the
`bin/` folder of the Sparkle release archive):

```bash
./bin/generate_keys
```

It stores the private key in your login keychain and prints the public key.

| Name | Kind | Value |
| :-- | :-- | :-- |
| `SPARKLE_PUBLIC_KEY` | variable | The printed public key |
| `SPARKLE_PRIVATE_KEY` | secret | Output of `./bin/generate_keys -x private.key`, then the contents of `private.key` (delete the file afterwards) |

Keep a backup of the private key. If it is lost, installed copies can no longer update and users must download the
next version by hand.

### Windows

Nothing is needed today: the Windows build is not code signed. Windows SmartScreen warns on first run; the website
and README tell users to click **More info > Run anyway**.

When the SignPath Foundation application is approved, add a signing step before `Pack with Velopack` in
`release.yml` (the place is marked in the file), and sign `Setup.exe` through `vpk pack --signTemplate`. Velopack also
reads `--azureTrustedSignFile` if Azure Trusted Signing is used instead.

### Website

Settings > Pages > Source: **GitHub Actions**. Then run **Website**. The site is at `https://nativescreen.app/`, set
as the custom domain under Settings > Pages. The address is `SITE` in `site/src/i18n/index.ts`, `site` in
`site/astro.config.mjs` and the sitemap line in `site/public/robots.txt`, so change them together if the domain changes.

The site is built with Astro. Run `npm ci` then `npm run dev` in `site/` to work on it. Every language is a file in
`site/src/i18n/`, and `en.ts` is the reference: a key missing from another language fails the build, so add new text to
all 8. After changing a headline, run `npm run og` (macOS with Chrome) to redraw the social preview images.

## Checking a release locally

- macOS: `spctl --assess --type open --context context:primary-signature -v NativeScreen.dmg` should say
  `accepted, source=Notarized Developer ID`. Mount it and run `spctl -a -vv "/Volumes/Native Screen/Native Screen.app"`.
- Sparkle: install the previous version, then `Native Screen > Check for Updates...` after publishing.
- Windows: run `NativeScreen-win-Setup.exe` on a clean machine, then publish a newer version and check that the app
  updates.
