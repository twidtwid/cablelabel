#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_root="$(mktemp -d)"
cleanup() {
  if command -v trash >/dev/null; then
    trash "$test_root"
  else
    /bin/rm -rf "$test_root"
  fi
}
trap cleanup EXIT

release_name="Cable-Labelmaker-v0.3.0-macOS-arm64"
release_root="$test_root/$release_name"
mkdir -p "$release_root/dist/Cable Labelmaker.app" \
  "$release_root/scripts/lib" "$release_root/macos"
printf '#!/bin/zsh\nexit 0\n' >"$release_root/scripts/install-macos-service.sh"
printf '#!/bin/zsh\nexit 0\n' >"$release_root/scripts/verify-macos-app.sh"
chmod +x "$release_root/scripts/install-macos-service.sh" \
  "$release_root/scripts/verify-macos-app.sh"
cp "$project_dir/scripts/lib/common.sh" "$release_root/scripts/lib/"
cp "$project_dir/macos/io.github.twidtwid.cablelabel.plist" "$release_root/macos/"

archive="$test_root/$release_name.zip"
/usr/bin/ditto -c -k --keepParent "$release_root" "$archive"
"$project_dir/scripts/verify-macos-release.sh" "$archive" >/dev/null

printf 'not a plist\n' >"$release_root/macos/io.github.twidtwid.cablelabel.plist"
/usr/bin/ditto -c -k --keepParent "$release_root" "$archive"
if "$project_dir/scripts/verify-macos-release.sh" "$archive" \
  >"$test_root/malformed.out" 2>&1; then
  echo "Release verifier accepted a malformed LaunchAgent plist" >&2
  exit 1
fi

echo "macOS release archive verification tests passed"
