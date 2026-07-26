#!/usr/bin/env bash
set -euo pipefail

APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
APP_PROCESS_NAME="${COPYCLIP_PROCESS_NAME:-CopyClipLite}"
BUNDLE_ID="${COPYCLIP_BUNDLE_ID:-io.github.38st.CopyClipLite}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/staging.noindex/$APP_DISPLAY_NAME.app"
DEST_DIR="${COPYCLIP_INSTALL_DIR:-/Applications}"
DEST_APP="$DEST_DIR/$APP_DISPLAY_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
OPEN_AFTER_INSTALL="${COPYCLIP_OPEN_AFTER_INSTALL:-1}"
INSTALL_ROOT=""
CANDIDATE_APP=""
BACKUP_APP=""
REPLACEMENT_COMPLETE=0
REPLACEMENT_STARTED=0

cleanup() {
  if [[ "$REPLACEMENT_STARTED" == "1" && "$REPLACEMENT_COMPLETE" != "1" ]]; then
    if [[ -e "$DEST_APP" ]]; then
      rm -rf "$DEST_APP"
    fi
    if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
      /bin/mv "$BACKUP_APP" "$DEST_APP" || true
    fi
  fi
  if [[ -n "$INSTALL_ROOT" && -d "$INSTALL_ROOT" ]]; then
    rm -rf "$INSTALL_ROOT"
  fi
  if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" ]]; then
    rm -rf "$BACKUP_APP"
  fi
}
trap cleanup EXIT

"$ROOT_DIR/script/build_and_run.sh" package

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing staged app: $SOURCE_APP" >&2
  exit 1
fi

SOURCE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$SOURCE_ID" != "$BUNDLE_ID" ]]; then
  echo "Staged app has unexpected bundle id: ${SOURCE_ID:-unknown}" >&2
  exit 3
fi

if [[ -e "$DEST_APP/Contents/Info.plist" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to overwrite $DEST_APP because it belongs to bundle id: ${EXISTING_ID:-unknown}" >&2
    exit 3
  fi
fi

mkdir -p "$DEST_DIR"
INSTALL_ROOT="$(mktemp -d "$DEST_DIR/.copycliplite-install.XXXXXX")"
CANDIDATE_APP="$INSTALL_ROOT/$APP_DISPLAY_NAME.app"
/usr/bin/ditto --rsrc --extattr "$SOURCE_APP" "$CANDIDATE_APP"

/usr/bin/plutil -lint "$CANDIDATE_APP/Contents/Info.plist" >/dev/null
CANDIDATE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$CANDIDATE_APP/Contents/Info.plist")"
if [[ "$CANDIDATE_ID" != "$BUNDLE_ID" ]]; then
  echo "Copied candidate has unexpected bundle id: $CANDIDATE_ID" >&2
  exit 4
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$CANDIDATE_APP"

pkill -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true

REPLACEMENT_STARTED=1
if [[ -e "$DEST_APP" ]]; then
  BACKUP_APP="$DEST_DIR/.$APP_DISPLAY_NAME.backup.$(/usr/bin/uuidgen).app"
  /bin/mv "$DEST_APP" "$BACKUP_APP"
fi

/bin/mv "$CANDIDATE_APP" "$DEST_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DEST_APP"
REPLACEMENT_COMPLETE=1

/usr/bin/touch "$DEST_APP"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP"
fi

/usr/bin/qlmanage -r cache >/dev/null 2>&1 || true
if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  /usr/bin/open "$DEST_APP"
fi

echo "$DEST_APP"
