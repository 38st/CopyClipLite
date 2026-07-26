# CopyClip Lite

CopyClip Lite is a lightweight native macOS clipboard history utility. It runs from the menu bar without a Dock icon, watches text and images copied to the system pasteboard, and keeps a small searchable history in Application Support.

## Features

- Menu bar panel with searchable clipboard history
- Plain text plus RTF/HTML text capture; PNG, TIFF, JPEG, HEIC/HEIF, and Finder-copied local image capture through one normalized PNG pipeline
- One-click copy back to the pasteboard
- Keyboard navigation with arrow keys and Return to copy the selected clip
- Global Option-Command-V hotkey to open clipboard search
- Pin, delete, clear, timed pause, and quit controls
- Quick filters for all clips, text, images, and pinned items
- JSON persistence with a configurable unpinned history limit
- Auto-clear options for unpinned clips: 24 hours, 7 days, 30 days, or never
- Pinned clips are preserved until manually deleted or cleared
- Optional clear of unpinned history when quitting
- App ignore list for skipping future clips from selected apps
- Versioned, same-version-compatible JSON history export and import
- Strategy-aware validated import preview with merge/replace projections and automatic pre-import backups
- Launch at Login setting for menu-bar startup
- Native macOS app bundle with Finder, Spotlight, Launchpad, and menu-bar access
- First-run welcome window

## Privacy

Clipboard history stays local on the Mac. CopyClip Lite does not upload clipboard contents, use an account, or send analytics.

History files use owner-only permissions (`0600`) inside an owner-only directory (`0700`). They are not separately encrypted; enable FileVault if clipboard confidentiality matters. JSON exports are also unencrypted and may contain sensitive text and images.

CopyClip Lite skips pasteboard data marked concealed, transient, or auto-generated. Source-app exclusions are best effort because macOS does not expose guaranteed clipboard ownership; the app checks the active application both while polling and immediately before application switches are recorded.

History is stored at:

```text
~/Library/Application Support/CopyClipLite/clipboard-history.json
```

Image files are stored locally under:

```text
~/Library/Application Support/CopyClipLite/Images
```

By default, CopyClip Lite keeps up to 50 unpinned clips and auto-clears unpinned clips after 7 days. Pinned clips never auto-clear.

Text clips over 20,000 characters, encoded images over 10 MB, and images over 100 megapixels are skipped with an in-app warning so unexpectedly large clipboard data cannot freeze the interface or exhaust storage.

Rich text is retained only when a plain-text representation can be extracted, and each optional RTF/HTML representation is capped at 10 MB. Image copy-back requires PNG; macOS may synthesize additional representations for destination compatibility without CopyClip eagerly decoding a TIFF on the main thread.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel Mac (release artifacts are universal)
- Accessibility permission only when the optional Direct Paste feature is enabled

## Run

Use the project-local run script:

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM target, stages `dist/staging.noindex/CopyClip Lite.app`, and launches it as a menu-bar macOS app bundle.

## Install

Use the installer script:

```bash
./script/install_app.sh
```

The script stages the app, installs it to `/Applications/CopyClip Lite.app`, refreshes LaunchServices and Quick Look icon caches, and opens the installed app.

## Sharing

Create a validated share zip from the staged bundle:

```bash
./script/package_release.sh
```

The script builds a release bundle, validates the bundle plist and code signature, writes `dist/CopyClip-Lite-macOS.zip`, verifies the zip, and reports the Gatekeeper assessment.

By default, local builds are ad-hoc signed and intended only for local validation. Public releases must use distribution mode, a Developer ID Application identity, and a `notarytool` keychain profile. The script signs with hardened runtime, submits to Apple, staples the ticket, rebuilds the ZIP, and requires Gatekeeper acceptance:

```bash
COPYCLIP_RELEASE_MODE=distribution \
COPYCLIP_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
COPYCLIP_NOTARY_PROFILE="CopyClipLiteNotary" \
./script/package_release.sh
```

Tagged releases (`vX.Y.Z`) run the same test/sign/notarize/staple flow through `.github/workflows/release.yml`. Configure the repository secrets documented in that workflow before publishing the first tag. CI validates tests, the package, and both `arm64` and `x86_64` slices on every pull request.

The production bundle identifier is `io.github.38st.CopyClipLite`. On first launch after upgrading from the former local bundle identifier, CopyClip Lite migrates existing preferences; clipboard history remains in the same Application Support directory.
