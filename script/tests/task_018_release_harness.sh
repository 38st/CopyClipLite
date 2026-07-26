#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/script/release_contract.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/copycliplite-task018.XXXXXX")"
cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for version in 0.0.0 1.2.3 2026.12.345; do
  copyclip_is_release_version "$version" \
    || fail "valid release version was rejected: $version"
done

for version in "" 1 1.0 1.0.0.0 v1.0.0 1.0.0-beta 01.2; do
  if copyclip_is_release_version "$version"; then
    fail "invalid release version was accepted: $version"
  fi
done

STAGING_DIR="$TEST_ROOT/staging"
APP_DISPLAY_NAME="CopyClip Lite"
APP_DIR="$STAGING_DIR/$APP_DISPLAY_NAME.app"
FIRST_ZIP="$TEST_ROOT/first.zip"
SECOND_ZIP="$TEST_ROOT/second.zip"
mkdir -p "$APP_DIR/Contents/MacOS"
printf 'deterministic payload\n' >"$APP_DIR/Contents/MacOS/CopyClipLite"
chmod +x "$APP_DIR/Contents/MacOS/CopyClipLite"

copyclip_create_release_zip \
  "$STAGING_DIR" \
  "$APP_DISPLAY_NAME" \
  "$FIRST_ZIP"
copyclip_verify_reproducible_zip \
  "$STAGING_DIR" \
  "$APP_DISPLAY_NAME" \
  "$FIRST_ZIP" \
  "$SECOND_ZIP"

printf 'changed payload\n' >"$APP_DIR/Contents/MacOS/CopyClipLite"
if copyclip_verify_reproducible_zip \
  "$STAGING_DIR" \
  "$APP_DISPLAY_NAME" \
  "$FIRST_ZIP" \
  "$SECOND_ZIP" >/dev/null 2>&1; then
  fail "changed staged app unexpectedly reproduced the verified ZIP"
fi

echo "PASS: one X.Y.Z release grammar and reproducible ZIP verification"
