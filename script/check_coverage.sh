#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIN_TOTAL="${COPYCLIP_MIN_TOTAL_LINE_COVERAGE:-50}"
MIN_STORAGE="${COPYCLIP_MIN_STORAGE_LINE_COVERAGE:-80}"
MIN_STORE="${COPYCLIP_MIN_STORE_LINE_COVERAGE:-75}"

cd "$ROOT_DIR"
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

TOTAL_PERCENT="$(jq -r '.data[0].totals.lines.percent' "$COVERAGE_PATH")"
STORAGE_PERCENT="$(percentage_for_suffix "Services/ClipboardStorage.swift")"
STORE_PERCENT="$(percentage_for_suffix "Stores/ClipboardStore.swift")"

assert_minimum "Total" "$TOTAL_PERCENT" "$MIN_TOTAL"
assert_minimum "ClipboardStorage" "$STORAGE_PERCENT" "$MIN_STORAGE"
assert_minimum "ClipboardStore" "$STORE_PERCENT" "$MIN_STORE"
