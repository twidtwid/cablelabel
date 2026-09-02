#!/usr/bin/env bash
set -euo pipefail

archive_path="${1:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "Linux release verification failed: $1" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing or empty file: $path"
}

[[ -n "$archive_path" ]] || fail "usage: $(basename "$0") ARCHIVE.tar.gz"
[[ -s "$archive_path" ]] || fail "archive not found or empty: $archive_path"

archive_name="$(basename "$archive_path")"
release_name="${archive_name%.tar.gz}"
[[ "$release_name" != "$archive_name" && -n "$release_name" ]] || \
  fail "archive name must end in .tar.gz"

extract_dir="$(mktemp -d)"
cleanup() {
  if command -v trash >/dev/null; then
    trash "$extract_dir"
  else
    rm -rf "$extract_dir"
  fi
}
trap cleanup EXIT

tar -xzf "$archive_path" -C "$extract_dir"
release_root="$extract_dir/$release_name"
installer="$release_root/scripts/install-linux-service.sh"
app_bundle="$release_root/dist/cablelabel"

[[ -x "$installer" ]] || fail "installer is missing or not executable"
require_file "$release_root/scripts/lib/common.sh"
require_file "$release_root/linux/cablelabel.service"
require_file "$release_root/linux/70-cablelabel-pt-d600.rules"
[[ -x "$release_root/dist/cablelabel/cablelabel" ]] || fail "default application bundle is missing"
require_file "$app_bundle/_internal/VERSION"
bundle_version="$(tr -d '[:space:]' <"$app_bundle/_internal/VERSION")"
"$script_dir/verify-linux-app.sh" "$app_bundle" "$bundle_version" >/dev/null || \
  fail "application bundle smoke verification failed"

awk '$0 == "ExecStart=%h/.local/opt/cablelabel/current/cablelabel" { found = 1 } END { exit !found }' \
  "$release_root/linux/cablelabel.service" || fail "systemd service has an unexpected ExecStart"
awk 'index($0, "OWNER=\"@CABLELABEL_USER@\"") { found = 1 } END { exit !found }' \
  "$release_root/linux/70-cablelabel-pt-d600.rules" || fail "udev rule is missing its user placeholder"

"$installer" --verify-only

echo "Verified Linux release archive: $archive_path"
