#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_path="${1:-$project_dir/dist/cablelabel}"
expected_version="${2:-}"

fail() {
  echo "Linux bundle verification failed: $1" >&2
  exit 1
}

[[ -d "$bundle_path" ]] || fail "bundle not found: $bundle_path"
if [[ -z "$expected_version" ]]; then
  expected_version="$(awk -F'"' '/^__version__ = / { print $2; exit }' \
    "$project_dir/cable_labelmaker/__init__.py")"
fi
[[ -n "$expected_version" ]] || fail "expected version was not provided or found"

actual_version="$("$project_dir/scripts/verify-linux-bundle-layout.sh" \
  "$bundle_path" "$expected_version")"
app_executable="$bundle_path/cablelabel"
ptouch_executable="$bundle_path/_internal/bin/ptouch"

cli_version="$($app_executable --version)"
[[ "$cli_version" == "cablelabel $expected_version" ]] || \
  fail "CLI version is incorrect: $cli_version"

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

"$app_executable" --json preview "LINUX CLI SMOKE" --output "$preview_path" >/dev/null
[[ "$(file "$preview_path")" == *"PNG image data"* ]] || fail "CLI preview is not a PNG"

"$app_executable" --json serve --port 0 --no-browser >"$app_log" 2>&1 &
app_pid=$!

healthy=0
for _attempt in {1..20}; do
  if ! kill -0 "$app_pid" 2>/dev/null; then
    cat "$app_log" >&2
    fail "packaged server exited before becoming healthy"
  fi
  app_url="$(sed -n 's/.*"url": "\([^"]*\)".*/\1/p' "$app_log" | head -n 1)"
  if [[ -n "$app_url" ]] &&
    curl --fail --silent --connect-timeout 1 --max-time 2 \
      "$app_url/api/health" | \
      cmp -s - <(printf '{"name": "cablelabel", "version": "%s"}' "$actual_version"); then
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
  "$app_url/api/preview" \
  -o "$preview_path"
kill -0 "$app_pid" 2>/dev/null || fail "packaged server exited during preview"
[[ "$(file "$preview_path")" == *"PNG image data"* ]] || fail "preview is not a PNG"

echo "Verified: $bundle_path (version $actual_version, $(uname -m))"
