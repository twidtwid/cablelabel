#!/usr/bin/env bash
set -euo pipefail

bundle_path="${1:-}"
expected_version="${2:-}"

fail() {
  echo "Linux bundle layout verification failed: $1" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing or empty file: $path"
}

[[ -n "$bundle_path" && -d "$bundle_path" ]] || fail "bundle not found: $bundle_path"
[[ -x "$bundle_path/cablelabel" ]] || fail "application executable is missing or not executable"
[[ -x "$bundle_path/_internal/bin/ptouch" ]] || fail "ptouch is missing or not executable"
require_file "$bundle_path/_internal/web/index.html"
require_file "$bundle_path/_internal/THIRD_PARTY_NOTICES.md"
require_file "$bundle_path/_internal/licenses/ptouch-rs-GPL-3.0.txt"
require_file "$bundle_path/_internal/fonts/RobotoCondensed-Bold.ttf"
require_file "$bundle_path/_internal/licenses/Roboto-Apache-2.0.txt"
require_file "$bundle_path/_internal/VERSION"

actual_version="$(tr -d '[:space:]' <"$bundle_path/_internal/VERSION")"
[[ -n "$actual_version" ]] || fail "bundle version is empty"
if [[ -n "$expected_version" && "$actual_version" != "$expected_version" ]]; then
  fail "expected version $expected_version, found $actual_version"
fi

printf '%s\n' "$actual_version"
