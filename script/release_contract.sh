#!/usr/bin/env bash

COPYCLIP_RELEASE_VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

copyclip_is_release_version() {
  local version="${1:-}"
  [[ "$version" =~ $COPYCLIP_RELEASE_VERSION_PATTERN ]]
}

copyclip_require_release_version() {
  local version="${1:-}"
  local label="${2:-Release version}"
  if ! copyclip_is_release_version "$version"; then
    echo "$label must use X.Y.Z: $version" >&2
    return 1
  fi
}

copyclip_create_release_zip() {
  local staging_dir="$1"
  local app_display_name="$2"
  local destination="$3"
  local ditto_command="${COPYCLIP_DITTO_COMMAND:-/usr/bin/ditto}"

  rm -f "$destination"
  mkdir -p "$(dirname "$destination")"
  (
    cd "$staging_dir"
    "$ditto_command" \
      -c -k \
      --keepParent \
      --norsrc \
      --noextattr \
      --noqtn \
      --noacl \
      "$app_display_name.app" \
      "$destination"
  )
}

copyclip_verify_reproducible_zip() {
  local staging_dir="$1"
  local app_display_name="$2"
  local verified_zip="$3"
  local reproduction_zip="$4"
  local cmp_command="${COPYCLIP_CMP_COMMAND:-/usr/bin/cmp}"

  copyclip_create_release_zip \
    "$staging_dir" \
    "$app_display_name" \
    "$reproduction_zip"
  if ! "$cmp_command" -s "$verified_zip" "$reproduction_zip"; then
    echo "Release ZIP packaging is not reproducible from the final staged app." >&2
    return 1
  fi
}
