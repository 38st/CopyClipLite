#!/usr/bin/env bash
set -euo pipefail

APP_DISPLAY_NAME="${COPYCLIP_APP_DISPLAY_NAME:-CopyClip Lite}"
BUNDLE_ID="${COPYCLIP_BUNDLE_ID:-io.github.38st.CopyClipLite}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="$ROOT_DIR/dist/staging.noindex/$APP_DISPLAY_NAME.app"
DEST_DIR="${COPYCLIP_INSTALL_DIR:-/Applications}"
DEST_APP="$DEST_DIR/$APP_DISPLAY_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

"$ROOT_DIR/script/build_and_run.sh" package

if [[ -e "$DEST_APP/Contents/Info.plist" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true)"

  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to overwrite $DEST_APP because it belongs to bundle id: ${EXISTING_ID:-unknown}" >&2
    exit 3
  fi
fi

/usr/bin/ditto --rsrc --extattr "$SOURCE_APP" "$DEST_APP"
/usr/bin/touch "$DEST_APP"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$DEST_APP"
fi

/usr/bin/qlmanage -r cache >/dev/null 2>&1 || true
/usr/bin/open "$DEST_APP"

echo "$DEST_APP"
