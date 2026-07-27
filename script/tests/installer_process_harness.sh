#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/copycliplite-installer-process.XXXXXX")"
REAL_SWIFT_COMMAND="$(command -v swift)"
PASS_COUNT=0

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $*"
}

assert_file() {
  [[ -e "$1" ]] || fail "expected file: $1"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected path to be absent: $1"
}

assert_log_contains() {
  grep -F "$2" "$1" >/dev/null || fail "expected '$2' in $1"
}

assert_log_excludes() {
  if grep -F "$2" "$1" >/dev/null; then
    fail "did not expect '$2' in $1"
  fi
}

assert_no_install_scratch() {
  local destination_dir="$1"
  local scratch
  scratch="$(find "$destination_dir" -maxdepth 1 -name '.copycliplite-install.*' -print -quit)"
  [[ -z "$scratch" ]] || fail "installer scratch directory remained: $scratch"
}

make_app() {
  local app_path="$1"
  local marker="$2"
  mkdir -p "$app_path/Contents/MacOS"
  cat >"$app_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>CopyClipLite</string>
  <key>CFBundleIdentifier</key>
  <string>io.github.38st.CopyClipLite</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
PLIST
  printf '%s\n' "$marker" >"$app_path/Contents/$marker"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$app_path/Contents/MacOS/CopyClipLite"
  chmod +x "$app_path/Contents/MacOS/CopyClipLite"
}

STUB_DIR="$TEST_ROOT/stubs"
mkdir -p "$STUB_DIR"

cat >"$STUB_DIR/swift-build" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "swift $*" >>"$EVENT_LOG"
if [[ "${FAIL_SWIFT_BUILD:-0}" == "1" && "$*" != *"--show-bin-path"* ]]; then
  exit 41
fi
if [[ "$*" == *"--show-bin-path"* ]]; then
  echo "$FAKE_BINARY_DIR"
fi
STUB

cat >"$STUB_DIR/codesign-build" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "codesign $*" >>"$EVENT_LOG"
STUB

cat >"$STUB_DIR/process-event" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$(basename "$0") $*" >>"$EVENT_LOG"
STUB

cat >"$STUB_DIR/install-build" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "install-build $*" >>"$EVENT_LOG"
[[ "${1:-}" == "package" ]] || exit 64
[[ "${FAIL_INSTALL_BUILD:-0}" != "1" ]] || exit 41
STUB

cat >"$STUB_DIR/ditto-install" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "ditto $*" >>"$EVENT_LOG"
[[ "${FAIL_DITTO:-0}" != "1" ]] || exit 42
exec /usr/bin/ditto "$@"
STUB

cat >"$STUB_DIR/codesign-install" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$CODESIGN_COUNTER" ]]; then
  count="$(<"$CODESIGN_COUNTER")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$CODESIGN_COUNTER"
echo "install-codesign-$count $*" >>"$EVENT_LOG"
if [[ "${FAIL_CODESIGN_CALL:-0}" == "$count" ]]; then
  exit 43
fi
STUB

cat >"$STUB_DIR/swap-runner" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$SWAP_COUNTER" ]]; then
  count="$(<"$SWAP_COUNTER")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$SWAP_COUNTER"
echo "atomic-swap-$count ${*:2}" >>"$EVENT_LOG"
if [[ "${FAIL_SWAP_CALL:-0}" == "$count" ]]; then
  exit 44
fi
exec "$REAL_SWIFT_COMMAND" "$@"
STUB

cat >"$STUB_DIR/install-event" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$(basename "$0") $*" >>"$EVENT_LOG"
STUB

chmod +x "$STUB_DIR"/*
ln -s "$STUB_DIR/swift-build" "$STUB_DIR/swift"
ln -s "$STUB_DIR/codesign-build" "$STUB_DIR/codesign"
ln -s "$STUB_DIR/process-event" "$STUB_DIR/pkill-build"
ln -s "$STUB_DIR/process-event" "$STUB_DIR/open-build"
ln -s "$STUB_DIR/install-event" "$STUB_DIR/pkill-install"
ln -s "$STUB_DIR/install-event" "$STUB_DIR/qlmanage-install"

BUILD_ROOT="$TEST_ROOT/build-workspace"
BUILD_BIN="$TEST_ROOT/build-bin"
BUILD_LOG="$TEST_ROOT/build-events.log"
mkdir -p "$BUILD_ROOT/Sources/CopyClipLite/Resources" "$BUILD_BIN"
printf 'icon\n' >"$BUILD_ROOT/Sources/CopyClipLite/Resources/CopyClipIcon.icns"
printf 'logo\n' >"$BUILD_ROOT/Sources/CopyClipLite/Resources/CopyClipLogo.png"
printf '#!/usr/bin/env bash\nexit 0\n' >"$BUILD_BIN/CopyClipLite"
chmod +x "$BUILD_BIN/CopyClipLite"

run_build_script() {
  env \
    PATH="$STUB_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    EVENT_LOG="$BUILD_LOG" \
    FAKE_BINARY_DIR="$BUILD_BIN" \
    FAIL_SWIFT_BUILD="${FAIL_SWIFT_BUILD:-0}" \
    COPYCLIP_ROOT_DIR="$BUILD_ROOT" \
    COPYCLIP_VERSION="1.2.3" \
    COPYCLIP_BUILD_NUMBER="17" \
    COPYCLIP_PKILL_COMMAND="$STUB_DIR/pkill-build" \
    COPYCLIP_OPEN_COMMAND="$STUB_DIR/open-build" \
    "$REPO_ROOT/script/build_and_run.sh" "$@"
}

: >"$BUILD_LOG"
if run_build_script invalid-mode >/dev/null 2>&1; then
  fail "invalid build mode unexpectedly succeeded"
fi
[[ ! -s "$BUILD_LOG" ]] || fail "invalid mode performed command side effects"
pass "invalid build mode fails before side effects"

: >"$BUILD_LOG"
run_build_script package >/dev/null
assert_log_contains "$BUILD_LOG" "swift build -c release --arch arm64 --arch x86_64"
assert_log_excludes "$BUILD_LOG" "pkill-build"
assert_log_excludes "$BUILD_LOG" "open-build"
pass "package mode builds without stopping or opening the app"

: >"$BUILD_LOG"
FAIL_SWIFT_BUILD=1
if run_build_script package >/dev/null 2>&1; then
  fail "failed package build unexpectedly succeeded"
fi
unset FAIL_SWIFT_BUILD
assert_log_excludes "$BUILD_LOG" "pkill-build"
assert_log_excludes "$BUILD_LOG" "open-build"
pass "failed package build leaves process lifecycle untouched"

: >"$BUILD_LOG"
run_build_script run >/dev/null
assert_log_contains "$BUILD_LOG" "pkill-build -x CopyClipLite"
assert_log_contains "$BUILD_LOG" "open-build -n $BUILD_ROOT/dist/staging.noindex/CopyClip Lite.app"
last_codesign_line="$(grep -n 'codesign' "$BUILD_LOG" | tail -1 | cut -d: -f1)"
pkill_line="$(grep -n 'pkill-build' "$BUILD_LOG" | cut -d: -f1)"
((pkill_line > last_codesign_line)) || fail "run mode stopped the app before build verification"
pass "run mode stops the app only after a verified build"

: >"$BUILD_LOG"
FAIL_SWIFT_BUILD=1
if run_build_script run >/dev/null 2>&1; then
  fail "failed run build unexpectedly succeeded"
fi
unset FAIL_SWIFT_BUILD
assert_log_excludes "$BUILD_LOG" "pkill-build"
assert_log_excludes "$BUILD_LOG" "open-build"
pass "failed run build preserves the running app"

run_atomic_swap_probe() {
  local probe_root="$TEST_ROOT/atomic-probe"
  mkdir -p "$probe_root/first" "$probe_root/second"
  printf 'old\n' >"$probe_root/first/old"
  printf 'new\n' >"$probe_root/second/new"
  "$REAL_SWIFT_COMMAND" "$REPO_ROOT/script/atomic_swap.swift" \
    "$probe_root/first" "$probe_root/second"
  assert_file "$probe_root/first/new"
  assert_file "$probe_root/second/old"
  "$REAL_SWIFT_COMMAND" "$REPO_ROOT/script/atomic_swap.swift" \
    "$probe_root/first" "$probe_root/second"
  assert_file "$probe_root/first/old"
  assert_file "$probe_root/second/new"
}

run_atomic_swap_probe
pass "Darwin rename swap atomically exchanges app directories and reverses cleanly"

prepare_install_case() {
  local case_root="$1"
  local with_existing="$2"
  local source_app="$case_root/workspace/dist/staging.noindex/CopyClip Lite.app"
  local destination_app="$case_root/Applications/CopyClip Lite.app"
  mkdir -p "$case_root/workspace/dist/staging.noindex" "$case_root/Applications"
  make_app "$source_app" "new-version"
  if [[ "$with_existing" == "1" ]]; then
    make_app "$destination_app" "old-version"
    printf 'stale\n' >"$destination_app/Contents/stale-from-old-version"
  fi
  : >"$case_root/events.log"
  : >"$case_root/codesign.count"
  : >"$case_root/swap.count"
}

run_install_case() {
  local case_root="$1"
  env \
    EVENT_LOG="$case_root/events.log" \
    CODESIGN_COUNTER="$case_root/codesign.count" \
    SWAP_COUNTER="$case_root/swap.count" \
    REAL_SWIFT_COMMAND="$REAL_SWIFT_COMMAND" \
    FAIL_INSTALL_BUILD="${FAIL_INSTALL_BUILD:-0}" \
    FAIL_DITTO="${FAIL_DITTO:-0}" \
    FAIL_CODESIGN_CALL="${FAIL_CODESIGN_CALL:-0}" \
    FAIL_SWAP_CALL="${FAIL_SWAP_CALL:-0}" \
    COPYCLIP_ROOT_DIR="$case_root/workspace" \
    COPYCLIP_INSTALL_DIR="$case_root/Applications" \
    COPYCLIP_BUILD_SCRIPT="$STUB_DIR/install-build" \
    COPYCLIP_DITTO_COMMAND="$STUB_DIR/ditto-install" \
    COPYCLIP_CODESIGN_COMMAND="$STUB_DIR/codesign-install" \
    COPYCLIP_PKILL_COMMAND="$STUB_DIR/pkill-install" \
    COPYCLIP_LSREGISTER="$case_root/not-present-lsregister" \
    COPYCLIP_QLMANAGE_COMMAND="$STUB_DIR/qlmanage-install" \
    COPYCLIP_OPEN_AFTER_INSTALL=0 \
    COPYCLIP_SWIFT_COMMAND="$STUB_DIR/swap-runner" \
    COPYCLIP_ATOMIC_SWAP_SCRIPT="$REPO_ROOT/script/atomic_swap.swift" \
    "$REPO_ROOT/script/install_app.sh"
}

INSTALL_SUCCESS="$TEST_ROOT/install-success"
prepare_install_case "$INSTALL_SUCCESS" 1
run_install_case "$INSTALL_SUCCESS" >/dev/null
SUCCESS_DEST="$INSTALL_SUCCESS/Applications/CopyClip Lite.app"
assert_file "$SUCCESS_DEST/Contents/new-version"
assert_missing "$SUCCESS_DEST/Contents/old-version"
assert_missing "$SUCCESS_DEST/Contents/stale-from-old-version"
assert_no_install_scratch "$INSTALL_SUCCESS/Applications"
assert_log_contains "$INSTALL_SUCCESS/events.log" "atomic-swap-1"
assert_log_contains "$INSTALL_SUCCESS/events.log" "pkill-install -x CopyClipLite"
verify_line="$(grep -n 'install-codesign-2' "$INSTALL_SUCCESS/events.log" | cut -d: -f1)"
install_pkill_line="$(grep -n 'pkill-install' "$INSTALL_SUCCESS/events.log" | cut -d: -f1)"
((install_pkill_line > verify_line)) || fail "installer stopped app before replacement verification"
pass "successful install atomically replaces the bundle and removes stale files"

INSTALL_BUILD_FAILURE="$TEST_ROOT/install-build-failure"
prepare_install_case "$INSTALL_BUILD_FAILURE" 1
FAIL_INSTALL_BUILD=1
if run_install_case "$INSTALL_BUILD_FAILURE" >/dev/null 2>&1; then
  fail "install build failure unexpectedly succeeded"
fi
unset FAIL_INSTALL_BUILD
assert_file "$INSTALL_BUILD_FAILURE/Applications/CopyClip Lite.app/Contents/old-version"
assert_log_excludes "$INSTALL_BUILD_FAILURE/events.log" "pkill-install"
pass "install build failure preserves the existing app"

INSTALL_COPY_FAILURE="$TEST_ROOT/install-copy-failure"
prepare_install_case "$INSTALL_COPY_FAILURE" 1
FAIL_DITTO=1
if run_install_case "$INSTALL_COPY_FAILURE" >/dev/null 2>&1; then
  fail "install copy failure unexpectedly succeeded"
fi
unset FAIL_DITTO
assert_file "$INSTALL_COPY_FAILURE/Applications/CopyClip Lite.app/Contents/old-version"
assert_no_install_scratch "$INSTALL_COPY_FAILURE/Applications"
assert_log_excludes "$INSTALL_COPY_FAILURE/events.log" "pkill-install"
pass "candidate copy failure preserves the existing app"

INSTALL_CANDIDATE_FAILURE="$TEST_ROOT/install-candidate-failure"
prepare_install_case "$INSTALL_CANDIDATE_FAILURE" 1
FAIL_CODESIGN_CALL=1
if run_install_case "$INSTALL_CANDIDATE_FAILURE" >/dev/null 2>&1; then
  fail "candidate verification failure unexpectedly succeeded"
fi
unset FAIL_CODESIGN_CALL
assert_file "$INSTALL_CANDIDATE_FAILURE/Applications/CopyClip Lite.app/Contents/old-version"
assert_no_install_scratch "$INSTALL_CANDIDATE_FAILURE/Applications"
assert_log_excludes "$INSTALL_CANDIDATE_FAILURE/events.log" "atomic-swap"
assert_log_excludes "$INSTALL_CANDIDATE_FAILURE/events.log" "pkill-install"
pass "candidate verification failure preserves the existing app"

INSTALL_POST_SWAP_FAILURE="$TEST_ROOT/install-post-swap-failure"
prepare_install_case "$INSTALL_POST_SWAP_FAILURE" 1
FAIL_CODESIGN_CALL=2
if run_install_case "$INSTALL_POST_SWAP_FAILURE" >/dev/null 2>&1; then
  fail "post-swap verification failure unexpectedly succeeded"
fi
unset FAIL_CODESIGN_CALL
POST_SWAP_DEST="$INSTALL_POST_SWAP_FAILURE/Applications/CopyClip Lite.app"
assert_file "$POST_SWAP_DEST/Contents/old-version"
assert_file "$POST_SWAP_DEST/Contents/stale-from-old-version"
assert_missing "$POST_SWAP_DEST/Contents/new-version"
assert_no_install_scratch "$INSTALL_POST_SWAP_FAILURE/Applications"
assert_log_contains "$INSTALL_POST_SWAP_FAILURE/events.log" "atomic-swap-2"
assert_log_excludes "$INSTALL_POST_SWAP_FAILURE/events.log" "pkill-install"
pass "post-swap verification failure atomically rolls back the old app"

INSTALL_SWAP_FAILURE="$TEST_ROOT/install-swap-failure"
prepare_install_case "$INSTALL_SWAP_FAILURE" 1
FAIL_SWAP_CALL=1
if run_install_case "$INSTALL_SWAP_FAILURE" >/dev/null 2>&1; then
  fail "atomic replacement failure unexpectedly succeeded"
fi
unset FAIL_SWAP_CALL
assert_file "$INSTALL_SWAP_FAILURE/Applications/CopyClip Lite.app/Contents/old-version"
assert_no_install_scratch "$INSTALL_SWAP_FAILURE/Applications"
assert_log_excludes "$INSTALL_SWAP_FAILURE/events.log" "pkill-install"
pass "atomic replacement failure leaves the old app in place"

INSTALL_ROLLBACK_FAILURE="$TEST_ROOT/install-rollback-failure"
prepare_install_case "$INSTALL_ROLLBACK_FAILURE" 1
FAIL_CODESIGN_CALL=2
FAIL_SWAP_CALL=2
if run_install_case "$INSTALL_ROLLBACK_FAILURE" >/dev/null 2>&1; then
  fail "rollback failure scenario unexpectedly succeeded"
fi
unset FAIL_CODESIGN_CALL FAIL_SWAP_CALL
assert_file "$INSTALL_ROLLBACK_FAILURE/Applications/CopyClip Lite.app/Contents/new-version"
preserved_old="$(find "$INSTALL_ROLLBACK_FAILURE/Applications" \
  -path '*/.copycliplite-install.*/*/Contents/old-version' -print -quit)"
[[ -n "$preserved_old" ]] || fail "failed rollback did not preserve the old bundle"
assert_log_excludes "$INSTALL_ROLLBACK_FAILURE/events.log" "pkill-install"
pass "failed automatic rollback preserves the old bundle for recovery"

INSTALL_FRESH="$TEST_ROOT/install-fresh"
prepare_install_case "$INSTALL_FRESH" 0
run_install_case "$INSTALL_FRESH" >/dev/null
assert_file "$INSTALL_FRESH/Applications/CopyClip Lite.app/Contents/new-version"
assert_no_install_scratch "$INSTALL_FRESH/Applications"
pass "fresh install moves a verified candidate into place"

echo "Installer process harness: $PASS_COUNT checks passed"
