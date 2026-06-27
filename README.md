# CopyClip Lite

CopyClip Lite is a lightweight native macOS clipboard history utility. It runs from the menu bar without a Dock icon, watches text and images copied to the system pasteboard, and keeps a small searchable history in Application Support.

## Features

- Menu bar panel with searchable clipboard history
- Text and image clipboard capture with image thumbnails
- One-click copy back to the pasteboard
- Pin, delete, clear, pause, and quit controls
- JSON persistence with a configurable unpinned history limit
- Auto-clear options for unpinned clips: 24 hours, 7 days, 30 days, or never
- Pinned clips are preserved until manually deleted or cleared
- Optional clear of unpinned history when quitting
- Launch at Login setting for menu-bar startup
- Native macOS app bundle with Finder, Spotlight, Launchpad, and menu-bar access
- First-run welcome window

## Privacy

Clipboard history stays local on the Mac. CopyClip Lite does not upload clipboard contents, use an account, or send analytics.

History is stored at:

```text
~/Library/Application Support/CopyClipLite/clipboard-history.json
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

Create the share zip from the staged bundle:

```bash
ditto -c -k --keepParent "dist/CopyClip Lite.app" "dist/CopyClip-Lite-macOS.zip"
```

The current local build is ad-hoc signed and intended for personal sharing, not App Store distribution.
