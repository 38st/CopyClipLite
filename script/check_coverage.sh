#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_SOURCE="${COPYCLIP_MIN_SOURCE_LINE_COVERAGE:-35}"
MIN_STORAGE="${COPYCLIP_MIN_STORAGE_LINE_COVERAGE:-80}"
MIN_STORE="${COPYCLIP_MIN_STORE_LINE_COVERAGE:-75}"
MIN_HOTKEY="${COPYCLIP_MIN_HOTKEY_LINE_COVERAGE:-30}"
MIN_LOGIN_ITEM="${COPYCLIP_MIN_LOGIN_ITEM_LINE_COVERAGE:-45}"
MIN_PASTE_TARGET="${COPYCLIP_MIN_PASTE_TARGET_LINE_COVERAGE:-75}"
MIN_UPDATER="${COPYCLIP_MIN_UPDATER_LINE_COVERAGE:-60}"
MIN_PERSISTENCE_GROUP="${COPYCLIP_MIN_PERSISTENCE_GROUP_LINE_COVERAGE:-60}"
MIN_STORE_PIPELINE_GROUP="${COPYCLIP_MIN_STORE_PIPELINE_GROUP_LINE_COVERAGE:-60}"
MIN_TRANSFER_GROUP="${COPYCLIP_MIN_TRANSFER_GROUP_LINE_COVERAGE:-60}"
MIN_PASTE_WORKFLOW_GROUP="${COPYCLIP_MIN_PASTE_WORKFLOW_GROUP_LINE_COVERAGE:-60}"

cd "$ROOT_DIR"
if ! command -v jq >/dev/null 2>&1; then
  echo "Coverage validation requires jq. Install it with 'brew install jq'." >&2
  exit 127
fi

swift test --enable-code-coverage
COVERAGE_PATH="$(swift test --show-codecov-path)"

if [[ ! -f "$COVERAGE_PATH" ]]; then
  echo "Missing coverage report: $COVERAGE_PATH" >&2
  exit 1
fi

percentage_for_suffix() {
  local suffix="$1"
  jq -r --arg suffix "$suffix" \
    '[.data[0].files[]
      | select((.filename // "") | endswith($suffix))
      | .summary.lines.percent][0] // 0' \
    "$COVERAGE_PATH"
}

percentage_for_suffixes() {
  local suffixes_json
  suffixes_json="$(jq -cn --args '$ARGS.positional' "$@")"
  jq -r --argjson suffixes "$suffixes_json" '
    [.data[0].files[]
      | select(
          (.filename // "") as $filename
          | any($suffixes[] as $suffix | $filename | endswith($suffix))
        )
      | .summary.lines]
    | (map(.covered) | add // 0) as $covered
    | (map(.count) | add // 0) as $count
    | if $count == 0 then 0 else ($covered * 100 / $count) end
  ' "$COVERAGE_PATH"
}

assert_minimum() {
  local label="$1"
  local actual="$2"
  local minimum="$3"
  if ! awk -v actual="$actual" -v minimum="$minimum" 'BEGIN { exit !(actual >= minimum) }'; then
    echo "$label line coverage $actual% is below the required $minimum%." >&2
    exit 2
  fi
  echo "$label line coverage: $actual% (minimum $minimum%)"
}

SOURCE_PERCENT="$(jq -r '
  [.data[0].files[]
    | select((.filename // "") | contains("/Sources/"))
    | .summary.lines]
  | (map(.covered) | add // 0) as $covered
  | (map(.count) | add // 0) as $count
  | if $count == 0 then 0 else ($covered * 100 / $count) end
' "$COVERAGE_PATH")"
STORAGE_PERCENT="$(percentage_for_suffix "Services/ClipboardStorage.swift")"
STORE_PERCENT="$(percentage_for_suffix "Stores/ClipboardStore.swift")"
HOTKEY_PERCENT="$(percentage_for_suffix "Services/GlobalHotkeyController.swift")"
LOGIN_ITEM_PERCENT="$(percentage_for_suffix "Services/LoginItemController.swift")"
PASTE_TARGET_PERCENT="$(percentage_for_suffix "Services/PasteTargetController.swift")"
UPDATER_PERCENT="$(percentage_for_suffix "Services/UpdateChecker.swift")"
PERSISTENCE_GROUP_PERCENT="$(percentage_for_suffixes \
  "Services/ClipboardStorage.swift" \
  "Services/ClipboardImageSidecarStore.swift" \
  "Services/ClipboardPersistenceCoordinator.swift")"
STORE_PIPELINE_GROUP_PERCENT="$(percentage_for_suffixes \
  "Stores/ClipboardStore.swift" \
  "Domain/ClipboardHistoryRules.swift" \
  "Domain/ClipboardImportPlanner.swift" \
  "Domain/ClipboardMonitoringPreferences.swift" \
  "Services/ClipboardCaptureReader.swift" \
  "Services/ClipboardImageCaptureQueue.swift" \
  "Services/ClipboardMonitoringSchedule.swift" \
  "Services/ClipboardThumbnailCache.swift" \
  "Services/ClipboardDragProviderFactory.swift" \
  "Services/ClipboardStoreTransferCoordinator.swift")"
TRANSFER_GROUP_PERCENT="$(percentage_for_suffixes \
  "Services/ClipboardTransferService.swift" \
  "Services/ClipboardTransferCodec.swift" \
  "Services/ClipboardTransferFormat.swift" \
  "Services/SettingsTransferCoordinator.swift")"
PASTE_WORKFLOW_GROUP_PERCENT="$(percentage_for_suffixes \
  "Services/PasteTargetController.swift" \
  "Services/PasteAttempt.swift")"

assert_minimum "Production source" "$SOURCE_PERCENT" "$MIN_SOURCE"
assert_minimum "ClipboardStorage" "$STORAGE_PERCENT" "$MIN_STORAGE"
assert_minimum "ClipboardStore" "$STORE_PERCENT" "$MIN_STORE"
assert_minimum "GlobalHotkeyController" "$HOTKEY_PERCENT" "$MIN_HOTKEY"
assert_minimum "LoginItemController" "$LOGIN_ITEM_PERCENT" "$MIN_LOGIN_ITEM"
assert_minimum "PasteTargetController" "$PASTE_TARGET_PERCENT" "$MIN_PASTE_TARGET"
assert_minimum "UpdateChecker" "$UPDATER_PERCENT" "$MIN_UPDATER"
assert_minimum \
  "Persistence components" \
  "$PERSISTENCE_GROUP_PERCENT" \
  "$MIN_PERSISTENCE_GROUP"
assert_minimum \
  "Store and capture pipeline" \
  "$STORE_PIPELINE_GROUP_PERCENT" \
  "$MIN_STORE_PIPELINE_GROUP"
assert_minimum \
  "Transfer components" \
  "$TRANSFER_GROUP_PERCENT" \
  "$MIN_TRANSFER_GROUP"
assert_minimum \
  "Paste workflow" \
  "$PASTE_WORKFLOW_GROUP_PERCENT" \
  "$MIN_PASTE_WORKFLOW_GROUP"
