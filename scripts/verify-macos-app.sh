#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="${1:-$project_dir/dist/Cable Labelmaker.app}"
expected_version="${2:-}"
expected_bundle_id="io.github.twidtwid.cablelabel"

fail() {
  echo "Bundle verification failed: $1" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -s "$path" ]] || fail "missing or empty file: $path"
}

[[ -d "$app_path" ]] || fail "app bundle not found: $app_path"

info_plist="$app_path/Contents/Info.plist"
require_file "$info_plist"
plutil -lint "$info_plist" >/dev/null

if [[ -z "$expected_version" ]]; then
  expected_version="$(awk -F'"' '/^__version__ = / { print $2; exit }' \
    "$project_dir/cable_labelmaker/__init__.py")"
fi
[[ -n "$expected_version" ]] || fail "expected version was not provided or found"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")"

[[ "$bundle_id" == "$expected_bundle_id" ]] || \
  fail "expected bundle identifier $expected_bundle_id, found $bundle_id"
[[ "$short_version" == "$expected_version" ]] || \
  fail "expected short version $expected_version, found $short_version"
[[ "$bundle_version" == "$expected_version" ]] || \
  fail "expected bundle version $expected_version, found $bundle_version"

main_executable="$app_path/Contents/MacOS/$bundle_executable"
ptouch_executable="$app_path/Contents/Resources/bin/ptouch"
[[ -x "$main_executable" ]] || fail "main executable is missing or not executable"
[[ -x "$ptouch_executable" ]] || fail "ptouch is missing or not executable"

require_file "$app_path/Contents/Resources/web/index.html"
require_file "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
require_file "$app_path/Contents/Resources/licenses/ptouch-rs-GPL-3.0.txt"

lipo "$main_executable" -verify_arch arm64 >/dev/null || \
  fail "main executable does not contain arm64"
lipo "$ptouch_executable" -verify_arch arm64 >/dev/null || \
  fail "ptouch does not contain arm64"

codesign --verify --deep --strict "$app_path" || fail "code signature is invalid"
echo "Verified: $app_path ($bundle_id $short_version, arm64)"
