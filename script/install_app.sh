#!/usr/bin/env bash
set -euo pipefail

APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
APP_PROCESS_NAME="${COPYCLIP_PROCESS_NAME:-CopyClipLite}"
BUNDLE_ID="${COPYCLIP_BUNDLE_ID:-io.github.38st.CopyClipLite}"
ROOT_DIR="${COPYCLIP_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SOURCE_APP="$ROOT_DIR/dist/staging.noindex/$APP_DISPLAY_NAME.app"
DEST_DIR="${COPYCLIP_INSTALL_DIR:-/Applications}"
DEST_APP="$DEST_DIR/$APP_DISPLAY_NAME.app"
OPEN_AFTER_INSTALL="${COPYCLIP_OPEN_AFTER_INSTALL:-1}"
BUILD_SCRIPT="${COPYCLIP_BUILD_SCRIPT:-$ROOT_DIR/script/build_and_run.sh}"
DITTO_COMMAND="${COPYCLIP_DITTO_COMMAND:-/usr/bin/ditto}"
PLUTIL_COMMAND="${COPYCLIP_PLUTIL_COMMAND:-/usr/bin/plutil}"
PLIST_BUDDY_COMMAND="${COPYCLIP_PLIST_BUDDY_COMMAND:-/usr/libexec/PlistBuddy}"
CODESIGN_COMMAND="${COPYCLIP_CODESIGN_COMMAND:-/usr/bin/codesign}"
PKILL_COMMAND="${COPYCLIP_PKILL_COMMAND:-pkill}"
TOUCH_COMMAND="${COPYCLIP_TOUCH_COMMAND:-/usr/bin/touch}"
LSREGISTER="${COPYCLIP_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
QLMANAGE_COMMAND="${COPYCLIP_QLMANAGE_COMMAND:-/usr/bin/qlmanage}"
OPEN_COMMAND="${COPYCLIP_OPEN_COMMAND:-/usr/bin/open}"
SWIFT_COMMAND="${COPYCLIP_SWIFT_COMMAND:-swift}"
ATOMIC_SWAP_SCRIPT="${COPYCLIP_ATOMIC_SWAP_SCRIPT:-$ROOT_DIR/script/atomic_swap.swift}"
INSTALL_ROOT=""
CANDIDATE_APP=""
REPLACEMENT_COMPLETE=0
EXISTING_APP_SWAPPED=0
NEW_APP_MOVED=0
ROLLBACK_FAILED=0

atomic_swap() {
  "$SWIFT_COMMAND" "$ATOMIC_SWAP_SCRIPT" "$1" "$2"
}

cleanup() {
  if [[ "$REPLACEMENT_COMPLETE" != "1" && "$EXISTING_APP_SWAPPED" == "1" ]]; then
    atomic_swap "$DEST_APP" "$CANDIDATE_APP" || {
      echo "Automatic rollback failed; the previous app remains at $CANDIDATE_APP" >&2
      ROLLBACK_FAILED=1
    }
  elif [[ "$REPLACEMENT_COMPLETE" != "1" && "$NEW_APP_MOVED" == "1" && -e "$DEST_APP" ]]; then
    /bin/mv "$DEST_APP" "$CANDIDATE_APP" || true
  fi
  if [[ "$ROLLBACK_FAILED" != "1" && -n "$INSTALL_ROOT" && -d "$INSTALL_ROOT" ]]; then
    rm -rf "$INSTALL_ROOT"
  fi
}
trap cleanup EXIT

"$BUILD_SCRIPT" package

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing staged app: $SOURCE_APP" >&2
  exit 1
fi

SOURCE_ID="$("$PLIST_BUDDY_COMMAND" -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$SOURCE_ID" != "$BUNDLE_ID" ]]; then
  echo "Staged app has unexpected bundle id: ${SOURCE_ID:-unknown}" >&2
  exit 3
fi

if [[ -e "$DEST_APP/Contents/Info.plist" ]]; then
  EXISTING_ID="$("$PLIST_BUDDY_COMMAND" -c 'Print CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to overwrite $DEST_APP because it belongs to bundle id: ${EXISTING_ID:-unknown}" >&2
    exit 3
  fi
fi

mkdir -p "$DEST_DIR"
# Keep the candidate on the destination volume so renameatx_np can exchange
# complete app directories without an interval where DEST_APP is missing.
INSTALL_ROOT="$(mktemp -d "$DEST_DIR/.copycliplite-install.XXXXXX")"
CANDIDATE_APP="$INSTALL_ROOT/$APP_DISPLAY_NAME.app"
"$DITTO_COMMAND" --rsrc --extattr "$SOURCE_APP" "$CANDIDATE_APP"

"$PLUTIL_COMMAND" -lint "$CANDIDATE_APP/Contents/Info.plist" >/dev/null
CANDIDATE_ID="$("$PLIST_BUDDY_COMMAND" -c 'Print CFBundleIdentifier' "$CANDIDATE_APP/Contents/Info.plist")"
if [[ "$CANDIDATE_ID" != "$BUNDLE_ID" ]]; then
  echo "Copied candidate has unexpected bundle id: $CANDIDATE_ID" >&2
  exit 4
fi
"$CODESIGN_COMMAND" --verify --deep --strict --verbose=2 "$CANDIDATE_APP"

if [[ -e "$DEST_APP" ]]; then
  # After the swap, the verified candidate is at DEST_APP and the previous app
  # remains at CANDIDATE_APP until post-replacement verification succeeds.
  atomic_swap "$DEST_APP" "$CANDIDATE_APP"
  EXISTING_APP_SWAPPED=1
else
  /bin/mv "$CANDIDATE_APP" "$DEST_APP"
  NEW_APP_MOVED=1
fi

"$CODESIGN_COMMAND" --verify --deep --strict --verbose=2 "$DEST_APP"
REPLACEMENT_COMPLETE=1

"$PKILL_COMMAND" -x "$APP_PROCESS_NAME" >/dev/null 2>&1 || true
"$TOUCH_COMMAND" "$DEST_APP"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP"
fi

"$QLMANAGE_COMMAND" -r cache >/dev/null 2>&1 || true
if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  "$OPEN_COMMAND" "$DEST_APP"
fi

echo "$DEST_APP"
