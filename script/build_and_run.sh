#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CopyClipLite"
APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
BUNDLE_ID="${COPYCLIP_BUNDLE_ID:-io.github.38st.CopyClipLite}"
GIT_VERSION="$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
APP_VERSION="${COPYCLIP_VERSION:-${GIT_VERSION:-1.0.0}}"
APP_BUILD_NUMBER="${COPYCLIP_BUILD_NUMBER:-$(git -C "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" rev-list --count HEAD)}"
MIN_SYSTEM_VERSION="14.0"
CODESIGN_IDENTITY="${COPYCLIP_CODESIGN_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging.noindex"
APP_BUNDLE="$STAGING_DIR/$APP_DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "Invalid bundle identifier: $BUNDLE_ID" >&2
  exit 3
fi
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Invalid app version: $APP_VERSION" >&2
  exit 3
fi
if [[ ! "$APP_BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number: $APP_BUILD_NUMBER" >&2
  exit 3
fi

mkdir -p "$STAGING_DIR"

CONFIGURATION="${COPYCLIP_BUILD_CONFIGURATION:-debug}"
if [[ "$MODE" == "package" || "$MODE" == "--package" ]]; then
  CONFIGURATION="${COPYCLIP_BUILD_CONFIGURATION:-release}"
fi

SWIFT_BUILD_ARGS=(-c "$CONFIGURATION")
if [[ "$CONFIGURATION" == "release" ]]; then
  read -r -a RELEASE_ARCHS <<<"${COPYCLIP_ARCHS:-arm64 x86_64}"
  for arch in "${RELEASE_ARCHS[@]}"; do
    SWIFT_BUILD_ARGS+=(--arch "$arch")
  done
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ROOT_DIR/Sources/CopyClipLite/Resources/CopyClipIcon.icns" "$APP_RESOURCES/CopyClipIcon.icns"
cp "$ROOT_DIR/Sources/CopyClipLite/Resources/CopyClipLogo.png" "$APP_RESOURCES/CopyClipLogo.png"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>CopyClipIcon</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSUIElement</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

CODESIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  CODESIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  package|--package)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [package|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
