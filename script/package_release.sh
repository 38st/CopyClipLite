#!/usr/bin/env bash
set -euo pipefail

APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/staging.noindex"
APP_BUNDLE="$STAGING_DIR/$APP_DISPLAY_NAME.app"
ZIP_PATH="${COPYCLIP_RELEASE_ZIP:-$DIST_DIR/CopyClip-Lite-macOS.zip}"
RELEASE_MODE="${COPYCLIP_RELEASE_MODE:-local}"
SIGNING_IDENTITY="${COPYCLIP_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${COPYCLIP_NOTARY_PROFILE:-}"
EXPECTED_VERSION="${COPYCLIP_EXPECTED_VERSION:-}"
VERIFY_LAUNCH="${COPYCLIP_VERIFY_LAUNCH:-1}"
VERIFY_DIR=""
VERIFY_PID=""

cleanup() {
  if [[ -n "$VERIFY_PID" ]]; then
    kill "$VERIFY_PID" >/dev/null 2>&1 || true
    wait "$VERIFY_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$VERIFY_DIR" ]]; then
    rm -rf "$VERIFY_DIR"
  fi
}
trap cleanup EXIT

case "$RELEASE_MODE" in
  local|distribution)
    ;;
  *)
    echo "COPYCLIP_RELEASE_MODE must be 'local' or 'distribution'." >&2
    exit 3
    ;;
esac

if [[ -n "$EXPECTED_VERSION" && ! "$EXPECTED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "COPYCLIP_EXPECTED_VERSION must use X.Y.Z." >&2
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
  if [[ -z "${COPYCLIP_UPDATE_FEED_URL:-}" ]]; then
    echo "Distribution releases require a public COPYCLIP_UPDATE_FEED_URL." >&2
    exit 5
  fi
fi

"$ROOT_DIR/script/build_and_run.sh" package

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Missing app bundle: $APP_BUNDLE" >&2
  exit 1
fi

STAGED_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_INFO_PLIST" >/dev/null
STAGED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$STAGED_INFO_PLIST")"
if [[ -n "$EXPECTED_VERSION" && "$STAGED_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Staged version $STAGED_VERSION does not match expected version $EXPECTED_VERSION." >&2
  exit 7
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

create_zip() {
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
}

create_zip

if [[ "$RELEASE_MODE" == "distribution" ]]; then
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate "$APP_BUNDLE"
  create_zip
fi

/usr/bin/unzip -tq "$ZIP_PATH" >/dev/null
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/copycliplite-release.XXXXXX")"
/usr/bin/unzip -q "$ZIP_PATH" -d "$VERIFY_DIR"

VERIFIED_APP="$VERIFY_DIR/$APP_DISPLAY_NAME.app"
VERIFIED_INFO_PLIST="$VERIFIED_APP/Contents/Info.plist"
VERIFIED_BINARY="$VERIFIED_APP/Contents/MacOS/CopyClipLite"

/usr/bin/plutil -lint "$VERIFIED_INFO_PLIST" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$VERIFIED_APP"

VERIFIED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$VERIFIED_INFO_PLIST")"
VERIFIED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$VERIFIED_INFO_PLIST")"
if [[ "$VERIFIED_VERSION" != "$STAGED_VERSION" ]]; then
  echo "Final ZIP version $VERIFIED_VERSION differs from staged version $STAGED_VERSION." >&2
  exit 8
fi
if [[ -n "$EXPECTED_VERSION" && "$VERIFIED_VERSION" != "$EXPECTED_VERSION" ]]; then
  echo "Final ZIP version $VERIFIED_VERSION does not match $EXPECTED_VERSION." >&2
  exit 8
fi
if [[ ! "$VERIFIED_BUILD" =~ ^[0-9]+$ || "$VERIFIED_BUILD" -lt 1 ]]; then
  echo "Final ZIP has invalid build number: $VERIFIED_BUILD" >&2
  exit 8
fi

ARCHS="$(/usr/bin/lipo -archs "$VERIFIED_BINARY")"
if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
  echo "Final ZIP is not universal: $ARCHS" >&2
  exit 9
fi

for resource in CopyClipIcon.icns CopyClipLogo.png; do
  if [[ ! -s "$VERIFIED_APP/Contents/Resources/$resource" ]]; then
    echo "Final ZIP is missing resource: $resource" >&2
    exit 10
  fi
done

if [[ "$RELEASE_MODE" == "distribution" ]]; then
  /usr/bin/xcrun stapler validate "$VERIFIED_APP"
  /usr/sbin/spctl -a -vv "$VERIFIED_APP"
elif /usr/sbin/spctl -a -vv "$VERIFIED_APP" >/dev/null 2>&1; then
  echo "Gatekeeper assessment: accepted"
else
  echo "Gatekeeper assessment: rejected (expected for ad-hoc signed local builds)"
fi

if [[ "$VERIFY_LAUNCH" == "1" ]]; then
  "$VERIFIED_BINARY" >/dev/null 2>&1 &
  VERIFY_PID="$!"
  sleep 2
  if ! kill -0 "$VERIFY_PID" >/dev/null 2>&1; then
    echo "Final extracted app did not remain running during launch verification." >&2
    exit 11
  fi
  kill "$VERIFY_PID" >/dev/null 2>&1 || true
  wait "$VERIFY_PID" >/dev/null 2>&1 || true
  VERIFY_PID=""
fi

ZIP_SHA256="$(/usr/bin/shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
echo "Verified version $VERIFIED_VERSION ($VERIFIED_BUILD), architectures: $ARCHS"
echo "SHA-256: $ZIP_SHA256"
echo "$ZIP_PATH"
