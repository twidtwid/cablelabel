#!/usr/bin/env bash
set -euo pipefail

archive_path="${1:-}"

fail() {
  echo "Linux release verification failed: $1" >&2
  exit 1
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

[[ -x "$installer" ]] || fail "installer is missing or not executable"
[[ -s "$release_root/scripts/lib/common.sh" ]] || fail "shared installer helper is missing"
[[ -x "$release_root/dist/cablelabel/cablelabel" ]] || fail "default application bundle is missing"

"$installer" --verify-only

echo "Verified Linux release archive: $archive_path"
