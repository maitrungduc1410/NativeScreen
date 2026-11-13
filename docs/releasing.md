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

## Microsoft Store (Windows)

Windows has two channels built from the same source (`spec/06` ADR-81):

| | GitHub (`Setup.exe`) | Microsoft Store (MSIX) |
| :-- | :-- | :-- |
| Built by | `windows` job: `dotnet publish` + `vpk pack` | `store` job: `windows/scripts/package-msix.ps1` (`NsPackage=true`) |
| Signed by | nobody yet (SmartScreen warns) | Microsoft, at certification |
| Updates | Velopack, from GitHub releases | the Store. The Store build has no Velopack and no update UI |
| MCP command | the exe path | the execution alias `%LOCALAPPDATA%\Microsoft\WindowsApps\nativescreen.exe` |
| Explorer "Open in Native Screen" | yes | no |

The `store` job runs only for stable versions (no `-beta` suffix, pre-release off). It uploads the `.msix` as the
`store-msix` artifact of the workflow run, not to the GitHub release, because an unsigned MSIX cannot be installed by
users. The package version is `major.minor.build.0` (the Store needs a zero revision), so every Store submission
needs a higher `major.minor.build` than the last one.

### Submitting

1. Run **Release** as usual. When it finishes, download `store-msix` from the run's summary page.
2. Partner Center > Apps and games > Native Screen > start a submission (or update it) > Packages: upload the
   `.msix`. Partner Center checks that its identity matches the reserved name.
3. Fill in the listing, age rating and privacy policy URL (the app asks for microphone and camera, so a privacy policy
   is required), and paste the certification notes below into **Submission options > Notes for certification**.
4. Submit. Certification takes from a few hours to a few days; Microsoft signs the package and the Store delivers it.

Submitting from CI with the `msstore` CLI (an Entra app: tenant id, client id, client secret, seller id) can be added
later. Until then, nothing in CI talks to Partner Center.

### Store identity

After the app name is reserved, Partner Center > Apps and games > Native Screen > Product management > **Product
identity** shows three values. Put them in **Settings > Secrets and variables > Actions > Variables**:

| Variable | Product identity field | Looks like |
| :-- | :-- | :-- |
| `NS_STORE_IDENTITY_NAME` | Package/Identity/Name | `<number>.<name>` |
| `NS_STORE_PUBLISHER` | Package/Identity/Publisher | `CN=<GUID>` |
| `NS_STORE_PUBLISHER_DISPLAY_NAME` | Package/Properties/PublisherDisplayName | your publisher name |

They are not secrets, but keep them out of the repository: `Package.appxmanifest` holds local values (`NativeScreen`,
`CN=NativeScreen`) so a test package builds anywhere, and the build writes the real ones into a copy under `obj/`
(MSBuild properties `NsStoreIdentityName`, `NsStorePublisher`, `NsStorePublisherDisplayName`). The `store` job stops
if any of them is missing. To build the Store package locally:

```powershell
powershell windows/scripts/package-msix.ps1 -IdentityName "<Name>" -Publisher "CN=<GUID>" -PublisherDisplayName "<Publisher>" -Version 1.2.0
```

Without arguments it builds a test package with the local identity. It also checks the package: every image the
manifest names, the native libraries and data files next to the exe, and no Velopack.

### Testing a package before submitting

On a test machine (this installs a certificate and an app, so not on a build machine you care about):

1. Make a self-signed certificate whose subject equals the package's `Publisher` (`CN=NativeScreen` for the local
   package), sign the `.msix` with `signtool sign /fd SHA256 /f <pfx> /p <password> <msix>`, and trust the certificate
   under Local Machine > Trusted People.
2. Install it (double-click the `.msix`, or `Add-AppxPackage <msix>`).
3. Run the Windows App Certification Kit: `appcert.exe test -appxpackagepath <msix> -reportoutputpath <report.xml>`.
   No failures are allowed.
4. Check the items in the `windows/HANDOFF.md` entry "Microsoft Store: an MSIX build next to the Velopack installer".

### Store listing

The Store page text and images for all 15 UI languages are in `windows/store-listing/` (see its README).

1. Partner Center > the submission > Store listings > **Import listings** > **Upload folder**, and pick
   `windows/store-listing` itself. Keep the folder name: every image path in `listing.csv` starts with `store-listing/`,
   because the upload sends each file as `<folder name>/<path>` and matches the CSV exactly. Without that prefix the
   import fails with "We couldn't process this .csv file" and no details. A CSV with text only (no image paths) imports
   either way.
2. Start from a fresh **Export listings** when Partner Center adds fields, and copy the values over. Keep the `Field`,
   `ID` and `Type` columns as exported, and save as UTF-8 with BOM and CRLF line ends. The descriptions are one
   paragraph: line breaks inside a cell were not tried after the first failed imports.
3. How it was made: the text comes from the website copy in `site/src/i18n/<language>.ts` (`lede`, the feature headings
   and paragraphs, `desc` as the short description), plus 7 search terms per language. The screenshots are a recording of
   `tools/demo-page` (made-up data) opened in an app window without an address bar, styled with zooms, captions and
   annotations, then opened with `NS_LANGUAGE=<id>` for each language with the caption and annotation text translated:
   a selected annotation (12.6 s) and the Export panel in the dark theme, and the Background tab in the light theme
   (9 s). The second shot is a camera-only recording with an AI background and a sticker, on the Camera Style tab.
   Each shot is the editor window's own pixels (`PrintWindow`), not a copy of the screen, so a notification on screen
   cannot end up in it. A caption block under the shot time is moved so its whole text shows: words get time in
   proportion to their length, so longer languages reveal their last word later. Arabic captions are typed in their
   normal order: both apps lay right-to-left lines out from the right (ADR-89). The Arabic shots were retaken on
   2026-11-14 after the Windows port.

**Restricted capabilities** asks why the app needs runFullTrust, in at most 500 characters:

```text
Native Screen is a WinUI 3 desktop screen recorder (packaged Win32, not UWP). It uses Windows.Graphics.Capture, WASAPI loopback for system audio, Media Foundation for camera, microphone and encoding, and Direct3D 11. During a recording it uses low-level mouse and keyboard hooks to save clicks and shortcuts for auto-zooms and keystroke overlays. It shows a tray icon. Everything runs on the device; nothing is uploaded.
```

### Notes for certification

Paste this into Partner Center > Submission options > **Notes for certification**:

```text
Native Screen is a free, open source screen recorder and video editor (Win32 desktop app, WinUI 3, packaged as MSIX).

How to test: the app starts as a small recording bar (also in the notification area). Pick Display, Window or Area and
press Record; press Stop in the bar to open the editor. Test recordings can be made without a microphone or camera.
"Create Interactive Showcase Project" in the notification area menu opens a sample project without recording anything.

Capabilities:
- runFullTrust: desktop app using Windows.Graphics.Capture for the screen, WASAPI loopback for system audio and
  Media Foundation for encoding.
- graphicsCaptureWithoutBorder: removes the yellow capture border so it does not appear around the recorded area.
  The user starts every recording; a countdown and the recording bar are always shown while recording.
- microphone, webcam: only when the user turns the microphone or camera on in the recording bar.
- internetClient: optional downloads of on-device models (speech to text, background removal) from Hugging Face when
  the user turns those features on. This build has no self-updater; updates come from the Store.

Keyboard and mouse hooks: while a recording is running (only then), the app uses low-level keyboard and mouse hooks to
record pointer positions, clicks and the names of pressed keys with their timestamps. They drive automatic zoom,
click effects and on-screen keycaps (shortcuts shown in the edited video, which the user can turn off). The data is
written to the recording's project folder on the user's PC and is never sent anywhere.

AI agents (off by default): Settings > AI Agents lets local MCP clients control the app through a named pipe that only
the current Windows user can open. The execution alias nativescreen.exe is what those clients start.

No account, no ads, no telemetry or analytics. Source code: https://github.com/maitrungduc1410/NativeScreen
```

## Mac App Store (macOS)

macOS has two channels built from the same source (`spec/06` ADR-85):

| | GitHub (`.dmg`) | Mac App Store |
| :-- | :-- | :-- |
| Xcode target | `NativeScreen` | `NativeScreen AppStore` (Swift flag `APPSTORE`) |
| Sandbox | off | on (`NativeScreen-AppStore.entitlements`) |
| Signed by | Developer ID, notarized | Apple, at review |
| Updates | Sparkle, from GitHub releases | the App Store. The target has no Sparkle and no update UI |
| AI Agents (MCP) | yes | no |
| Resize another app's window from the picker | yes | no (needs Accessibility) |
| Keystrokes for keycaps | Accessibility | Input Monitoring (listen-only event tap) |
| Default projects folder | `~/Native Screen Projects` | `~/Movies/Native Screen Projects` |
| MP4 codec `Both` | yes | no (the second file is outside what the save panel grants) |

Both use the bundle ID `com.dmai.NativeScreen`. Nothing in CI builds the App Store version yet.

### Submitting

1. App Store Connect > Apps > **+** > New App, platform macOS, bundle ID `com.dmai.NativeScreen`, SKU of your choice.
   Fill in the listing, the privacy policy URL (`https://nativescreen.app/privacy/`) and App Privacy ("Data Not
   Collected"). Screenshots are in `macos/store-listing/screenshots/en-us/` (see its README).
2. Archive on a Mac with the version of the release:

   ```bash
   xcodebuild -project macos/NativeScreen.xcodeproj -scheme "NativeScreen AppStore" -configuration Release \
     MARKETING_VERSION=1.2.0 CURRENT_PROJECT_VERSION=42 archive -archivePath build/NativeScreen-AppStore.xcarchive
   ```

   `CURRENT_PROJECT_VERSION` must grow with every upload.
3. Open the archive in Xcode (Window > Organizer) > Distribute App > App Store Connect > Upload. Xcode signs it with
   the Apple Distribution certificate and a Mac App Store profile (automatic signing makes both).
4. In App Store Connect, pick the build for the version, answer the export compliance question (the app uses no
   encryption beyond the system's; `ITSAppUsesNonExemptEncryption` is `NO`), paste the review notes below, and submit.

### Notes for review

```text
Native Screen is a free, open source screen recorder and video editor. No account is needed.

How to test: click the menu bar icon or the floating bar, pick a display, window or area, and press Record. Press
Stop to open the editor, then Export.

Permissions: Screen Recording (to record), Microphone and Camera (both off until turned on in the bar), Speech
Recognition (captions, on device only), and Input Monitoring. Input Monitoring is used only while recording, through a
listen-only event tap, to show the keyboard shortcuts the user pressed as on-screen keycaps in the video. Keystrokes
are written into the project on the user's Mac and never leave it.

Projects are saved in ~/Movies/Native Screen Projects unless the user picks another folder.
```

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
