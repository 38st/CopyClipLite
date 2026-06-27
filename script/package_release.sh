#!/usr/bin/env bash
set -euo pipefail

APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging.noindex"
APP_BUNDLE="$STAGING_DIR/$APP_DISPLAY_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
ZIP_PATH="${COPYCLIP_RELEASE_ZIP:-$DIST_DIR/CopyClip-Lite-macOS.zip}"
VERIFY_DIR=""

cleanup() {
  if [[ -n "$VERIFY_DIR" ]]; then
    rm -rf "$VERIFY_DIR"
  fi
}
trap cleanup EXIT

"$ROOT_DIR/script/build_and_run.sh" package

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

rm -f "$ZIP_PATH"
mkdir -p "$(dirname "$ZIP_PATH")"

(
  cd "$STAGING_DIR"
  /usr/bin/ditto \
    -c -k \
    --keepParent \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$APP_DISPLAY_NAME.app" \
    "$ZIP_PATH"
)

/usr/bin/unzip -tq "$ZIP_PATH" >/dev/null
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/copycliplite-release.XXXXXX")"
/usr/bin/unzip -q "$ZIP_PATH" -d "$VERIFY_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFY_DIR/$APP_DISPLAY_NAME.app"

if /usr/sbin/spctl -a -vv "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "Gatekeeper assessment: accepted"
elif [[ "${COPYCLIP_CODESIGN_IDENTITY:--}" == "-" ]]; then
  echo "Gatekeeper assessment: rejected (expected for ad-hoc signed local builds)"
else
  echo "Gatekeeper assessment: rejected (Developer ID builds usually need notarization and stapling)"
fi

echo "$ZIP_PATH"
