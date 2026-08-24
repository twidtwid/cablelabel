#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_path="${1:-$project_dir/dist/cablelabel}"
expected_version="${2:-}"

fail() {
  echo "Linux bundle verification failed: $1" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing or empty file: $path"
}

[[ -d "$bundle_path" ]] || fail "bundle not found: $bundle_path"
if [[ -z "$expected_version" ]]; then
  expected_version="$(awk -F'"' '/^__version__ = / { print $2; exit }' \
    "$project_dir/cable_labelmaker/__init__.py")"
fi
[[ -n "$expected_version" ]] || fail "expected version was not provided or found"

app_executable="$bundle_path/cablelabel"
ptouch_executable="$bundle_path/_internal/bin/ptouch"
[[ -x "$app_executable" ]] || fail "application executable is missing or not executable"
[[ -x "$ptouch_executable" ]] || fail "ptouch is missing or not executable"
require_file "$bundle_path/_internal/web/index.html"
require_file "$bundle_path/_internal/THIRD_PARTY_NOTICES.md"
require_file "$bundle_path/_internal/licenses/ptouch-rs-GPL-3.0.txt"
require_file "$bundle_path/_internal/VERSION"

actual_version="$(tr -d '[:space:]' <"$bundle_path/_internal/VERSION")"
[[ "$actual_version" == "$expected_version" ]] || \
  fail "expected version $expected_version, found $actual_version"

case "$(uname -m)" in
  x86_64)
    [[ "$(file "$app_executable")" == *x86-64* ]] || fail "application is not x86_64"
    [[ "$(file "$ptouch_executable")" == *x86-64* ]] || fail "ptouch is not x86_64"
    ;;
  aarch64|arm64)
    [[ "$(file "$app_executable")" == *aarch64* ]] || fail "application is not arm64"
    [[ "$(file "$ptouch_executable")" == *aarch64* ]] || fail "ptouch is not arm64"
    ;;
  *)
    fail "unsupported verification architecture: $(uname -m)"
    ;;
esac

preview_path="$(mktemp)"
app_log="$(mktemp)"
app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  rm -f "$preview_path" "$app_log"
}
trap cleanup EXIT

port=$((20000 + $$ % 20000))
CABLELABEL_PORT="$port" CABLELABEL_OPEN_BROWSER=0 \
  "$app_executable" >"$app_log" 2>&1 &
app_pid=$!

healthy=0
for _attempt in {1..20}; do
  if curl --fail --silent --connect-timeout 1 --max-time 2 \
    "http://127.0.0.1:$port/" >/dev/null; then
    healthy=1
    break
  fi
  sleep 1
done
if (( ! healthy )); then
  cat "$app_log" >&2
  fail "packaged server did not become healthy"
fi

curl --fail --silent --show-error --max-time 5 \
  -H 'Content-Type: application/json' \
  -d '{"label":"LINUX BUNDLE SMOKE","length":48}' \
  "http://127.0.0.1:$port/api/preview" \
  -o "$preview_path"
[[ "$(file "$preview_path")" == *"PNG image data"* ]] || fail "preview is not a PNG"

echo "Verified: $bundle_path (version $actual_version, $(uname -m))"
