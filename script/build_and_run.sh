#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  package|--package|run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    echo "usage: $0 [package|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${COPYCLIP_ROOT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
source "$SCRIPT_DIR/release_contract.sh"
APP_NAME="CopyClipLite"
APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
BUNDLE_ID="${COPYCLIP_BUNDLE_ID:-io.github.38st.CopyClipLite}"

discover_git_version() {
  local best_distance=""
  local best_version=""
  local distance
  local tag
  local version

  while IFS= read -r tag; do
    version="${tag#v}"
    if [[ "$tag" != "v$version" ]] || ! copyclip_is_release_version "$version"; then
      continue
    fi
    distance="$(git -C "$ROOT_DIR" rev-list --count "$tag..HEAD" 2>/dev/null || true)"
    if [[ ! "$distance" =~ ^[0-9]+$ ]]; then
      continue
    fi
    if [[ -z "$best_distance" || "$distance" -lt "$best_distance" ]]; then
      best_distance="$distance"
      best_version="$version"
    fi
  done < <(git -C "$ROOT_DIR" tag --merged HEAD --sort=-version:refname 2>/dev/null || true)

  printf '%s' "$best_version"
}

GIT_VERSION="$(discover_git_version)"
APP_VERSION="${COPYCLIP_VERSION:-${GIT_VERSION:-1.0.0}}"
APP_BUILD_NUMBER="${COPYCLIP_BUILD_NUMBER:-$(git -C "$ROOT_DIR" rev-list --count HEAD)}"
UPDATE_FEED_URL="${COPYCLIP_UPDATE_FEED_URL:-}"
MIN_SYSTEM_VERSION="14.0"
CODESIGN_IDENTITY="${COPYCLIP_CODESIGN_IDENTITY:--}"
PKILL_COMMAND="${COPYCLIP_PKILL_COMMAND:-pkill}"
OPEN_COMMAND="${COPYCLIP_OPEN_COMMAND:-/usr/bin/open}"
LLDB_COMMAND="${COPYCLIP_LLDB_COMMAND:-lldb}"
LOG_COMMAND="${COPYCLIP_LOG_COMMAND:-/usr/bin/log}"
SLEEP_COMMAND="${COPYCLIP_SLEEP_COMMAND:-sleep}"
PGREP_COMMAND="${COPYCLIP_PGREP_COMMAND:-pgrep}"

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
if ! copyclip_require_release_version "$APP_VERSION" "App version"; then
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

swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
SOURCE_RESOURCES="$ROOT_DIR/Sources/CopyClipLite/Resources"
cp "$SOURCE_RESOURCES/CopyClipIcon.icns" "$APP_RESOURCES/CopyClipIcon.icns"
cp "$SOURCE_RESOURCES/CopyClipLogo.png" "$APP_RESOURCES/CopyClipLogo.png"
while IFS= read -r -d '' localization_dir; do
  relative_path="${localization_dir#"$SOURCE_RESOURCES/"}"
  mkdir -p "$(dirname "$APP_RESOURCES/$relative_path")"
  cp -R "$localization_dir" "$APP_RESOURCES/$relative_path"
done < <(find "$SOURCE_RESOURCES" -type d -name '*.lproj' -print0)

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

if [[ -n "$UPDATE_FEED_URL" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CopyClipUpdateFeedURL string $UPDATE_FEED_URL" "$INFO_PLIST"
fi

CODESIGN_ARGS=(--force --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
  CODESIGN_ARGS+=(--options runtime --timestamp)
fi

codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

stop_running_copy() {
  "$PKILL_COMMAND" -x "$APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
  "$OPEN_COMMAND" -n "$APP_BUNDLE"
}

case "$MODE" in
  package|--package)
    ;;
  run)
    stop_running_copy
    open_app
    ;;
  --debug|debug)
    stop_running_copy
    "$LLDB_COMMAND" -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_running_copy
    open_app
    "$LOG_COMMAND" stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_running_copy
    open_app
    "$LOG_COMMAND" stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_running_copy
    open_app
    "$SLEEP_COMMAND" 1
    "$PGREP_COMMAND" -x "$APP_NAME" >/dev/null
    ;;
esac
