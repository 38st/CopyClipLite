# CopyClip Lite

[![CI](https://github.com/38st/CopyClipLite/actions/workflows/ci.yml/badge.svg)](https://github.com/38st/CopyClipLite/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/38st/CopyClipLite)](https://github.com/38st/CopyClipLite/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

CopyClip Lite is a lightweight native macOS clipboard history utility. It runs from the menu bar without a Dock icon, watches text and images copied to the system pasteboard, and keeps a small searchable history in Application Support.

## Features

- Menu bar panel with searchable clipboard history
- Plain text plus RTF/HTML text capture; PNG, TIFF, JPEG, HEIC/HEIF, and Finder-copied local image capture through one normalized PNG pipeline
- One-click copy back to the pasteboard
- Native drag-out for plain/rich text and PNG images, plus validated JSON drop-import in Settings
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
- VoiceOver-aware keyboard selection, named row actions, and Reduce Motion-aware scrolling

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

Text clips over 20,000 characters, encoded images over 10 MB, and images over approximately 16.8 megapixels are skipped with an in-app warning so unexpectedly large clipboard data cannot freeze the interface or exhaust storage.

Rich text is retained only when a plain-text representation can be extracted, and each optional RTF/HTML representation is capped at 10 MB. Image copy-back requires PNG; macOS may synthesize additional representations for destination compatibility without CopyClip eagerly decoding a TIFF on the main thread.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon or Intel Mac (release artifacts are universal)
- Accessibility permission only when the optional Direct Paste feature is enabled

## Install

Download `CopyClip-Lite-macOS.zip` from the
[latest GitHub release](https://github.com/38st/CopyClipLite/releases/latest),
extract it, and move **CopyClip Lite.app** to Applications.

Release builds are ad-hoc signed and not notarized. On first launch, macOS may
require you to Control-click the app, choose **Open**, and confirm.

To build and install directly from source instead:

```bash
./script/install_app.sh
```

The installer stages the app, installs it to `/Applications/CopyClip Lite.app`,
refreshes LaunchServices and Quick Look icon caches, and opens the installed
app.

## Development

Use the project-local run script:

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM target, stages `dist/staging.noindex/CopyClip Lite.app`, and launches it as a menu-bar macOS app bundle.

Run the test suite with:

```bash
swift test
```

The complete coverage check also requires `jq` (`brew install jq`).

See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete validation workflow and
[the accessibility test matrix](docs/accessibility-testing.md) for manual
release checks.

## Releases

Create a validated release ZIP from the staged bundle:

```bash
./script/package_release.sh
```

The script builds an ad-hoc signed release bundle, validates the bundle plist and signature integrity, writes `dist/CopyClip-Lite-macOS.zip`, reproduces the final ZIP byte-for-byte from the staged app, verifies the ZIP, launch-smoke-tests a fresh extraction, and reports the expected Gatekeeper assessment.

The project does not require an Apple Developer Program account. Its selected release scope is ad-hoc signing rather than Developer ID signing/notarization. Optional Developer ID distribution remains supported by the packaging script for a future maintainer.

Published app versions use one `X.Y.Z` grammar, and release tags use the matching `vX.Y.Z` form. Tagged releases run tests and the same ad-hoc package verification through `.github/workflows/release.yml` without Apple secrets. The workflow creates a draft with the Gatekeeper warning, downloads the uploaded ZIP, verifies its SHA-256 against the locally verified artifact, and only then publishes the release. CI validates tests, the release contract, the package, and both `arm64` and `x86_64` slices on every pull request.

Local builds intentionally omit the update feed and report that no public
channel is configured. The tagged-release workflow embeds the GitHub Releases
endpoint in the verified ad-hoc build.

The production bundle identifier is `io.github.38st.CopyClipLite`. On first launch after upgrading from the former local bundle identifier, CopyClip Lite migrates existing preferences; clipboard history remains in the same Application Support directory.

## License

CopyClip Lite is available under the [MIT License](LICENSE).

Please report security concerns according to [SECURITY.md](SECURITY.md).
