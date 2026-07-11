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
RELEASE_MODE="${COPYCLIP_RELEASE_MODE:-local}"
SIGNING_IDENTITY="${COPYCLIP_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${COPYCLIP_NOTARY_PROFILE:-}"

cleanup() {
  if [[ -n "$VERIFY_DIR" ]]; then
    rm -rf "$VERIFY_DIR"
  fi
}
trap cleanup EXIT

if [[ "$RELEASE_MODE" != "local" && "$RELEASE_MODE" != "distribution" ]]; then
  echo "COPYCLIP_RELEASE_MODE must be 'local' or 'distribution'." >&2
  exit 3
fi

if [[ "$RELEASE_MODE" == "distribution" ]]; then
  if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    echo "Distribution releases require COPYCLIP_CODESIGN_IDENTITY='Developer ID Application: …'" >&2
    exit 4
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "Distribution releases require COPYCLIP_NOTARY_PROFILE for notarytool." >&2
    exit 5
  fi
fi

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

if [[ "$RELEASE_MODE" == "distribution" ]]; then
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"

  rm -f "$ZIP_PATH"
  (
    cd "$STAGING_DIR"
    /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
      "$APP_DISPLAY_NAME.app" "$ZIP_PATH"
  )
  /usr/bin/unzip -tq "$ZIP_PATH" >/dev/null
fi

if /usr/sbin/spctl -a -vv "$APP_BUNDLE" >/dev/null 2>&1; then
  echo "Gatekeeper assessment: accepted"
elif [[ "$RELEASE_MODE" == "distribution" ]]; then
  echo "Gatekeeper rejected the notarized distribution artifact" >&2
  exit 6
elif [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Gatekeeper assessment: rejected (expected for ad-hoc signed local builds)"
else
  echo "Gatekeeper assessment: rejected (Developer ID builds usually need notarization and stapling)"
fi

echo "$ZIP_PATH"
