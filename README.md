# CopyClip Lite

CopyClip Lite is a lightweight native macOS clipboard history utility. It runs from the menu bar without a Dock icon, watches text and images copied to the system pasteboard, and keeps a small searchable history in Application Support.

## Features

- Menu bar panel with searchable clipboard history
- Text and image clipboard capture with image thumbnails and lightweight on-disk image files
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
- History export and import
- Launch at Login setting for menu-bar startup
- Native macOS app bundle with Finder, Spotlight, Launchpad, and menu-bar access
- First-run welcome window

## Privacy

Clipboard history stays local on the Mac. CopyClip Lite does not upload clipboard contents, use an account, or send analytics.

History is stored at:

```text
~/Library/Application Support/CopyClipLite/clipboard-history.json
```

Image files are stored locally under:

```text
~/Library/Application Support/CopyClipLite/Images
```

By default, CopyClip Lite keeps up to 50 unpinned clips and auto-clears unpinned clips after 7 days. Pinned clips never auto-clear.

## Run

Use the project-local run script:

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM target, stages `dist/CopyClip Lite.app`, and launches it as a menu-bar macOS app bundle.

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

By default, local builds are ad-hoc signed and intended for personal sharing, not App Store distribution. To create a Developer ID signed build for notarization, provide a signing identity:

```bash
COPYCLIP_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./script/package_release.sh
```
