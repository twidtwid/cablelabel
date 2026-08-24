#!/bin/zsh
set -euo pipefail

archive_path="${1:-}"

fail() {
  echo "macOS release verification failed: $1" >&2
  exit 1
}

[[ -n "$archive_path" ]] || fail "usage: ${0:t} ARCHIVE.zip"
[[ -s "$archive_path" ]] || fail "archive not found or empty: $archive_path"

archive_name="${archive_path:t}"
release_name="${archive_name%.zip}"
[[ "$release_name" != "$archive_name" && -n "$release_name" ]] || \
  fail "archive name must end in .zip"
version="${release_name#Cable-Labelmaker-v}"
version="${version%-macOS-arm64}"
[[ "$version" == <->.<->.<-> ]] || fail "archive name does not contain a semantic version"

extract_dir="$(mktemp -d)"
cleanup() {
  if command -v trash >/dev/null; then
    trash "$extract_dir"
  else
    /bin/rm -rf "$extract_dir"
  fi
}
trap cleanup EXIT

/usr/bin/ditto -x -k "$archive_path" "$extract_dir"
release_root="$extract_dir/$release_name"
installer="$release_root/scripts/install-macos-service.sh"
app_path="$release_root/dist/Cable Labelmaker.app"

[[ -x "$installer" ]] || fail "installer is missing or not executable"
[[ -s "$release_root/scripts/lib/common.sh" ]] || fail "shared installer helper is missing"
[[ -s "$release_root/macos/io.github.twidtwid.cablelabel.plist" ]] || \
  fail "LaunchAgent template is missing"
[[ -d "$app_path" ]] || fail "application bundle is missing"

/bin/zsh -n "$installer"
"$release_root/scripts/verify-macos-app.sh" "$app_path" "$version"

echo "Verified macOS release archive: $archive_path"
