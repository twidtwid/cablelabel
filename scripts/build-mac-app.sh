#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"
ptouch_url="https://github.com/vowstar/ptouch-rs/releases/download/v${PTOUCH_VERSION}/ptouch-macos-arm64"
ptouch_sha="1645b7e985a4704ba74173acfff3a71ba0b0f3c6d01e99061003b3f956ee6fa1"

cd "$project_dir"

uv_bin="$(command -v uv || true)"
if [[ -z "$uv_bin" ]]; then
  echo "uv is required. Install it with Homebrew: brew install uv" >&2
  exit 1
fi

if [[ ! -x .venv/bin/python ]]; then
  "$uv_bin" venv --python 3.12 .venv
fi

"$uv_bin" pip install --python .venv/bin/python -r requirements.txt -r requirements-build.txt
app_version="$(.venv/bin/python -c 'from cable_labelmaker import __version__; print(__version__)')"
if ! validate_app_version "$app_version"; then
  echo "App version must contain two or three numeric components: $app_version" >&2
  exit 1
fi
mkdir -p bin build/icon.iconset build/licenses

download_verified "$ptouch_url" "$ptouch_sha" bin/ptouch "ptouch"
chmod 755 bin/ptouch

ptouch_license="build/licenses/ptouch-rs-GPL-3.0.txt"
download_verified \
  "$PTOUCH_LICENSE_URL" \
  "$PTOUCH_LICENSE_SHA" \
  "$ptouch_license" \
  "ptouch license"

magick_bin="$(command -v magick || true)"
if [[ -z "$magick_bin" ]]; then
  echo "ImageMagick 'magick' is not on PATH. Install it with Homebrew." >&2
  exit 1
fi
"$magick_bin" -background none assets/icon.svg build/icon-1024.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/icon-1024.png --out "build/icon.iconset/icon_${size}x${size}.png" >/dev/null
  if [[ "$size" -lt 512 ]]; then
    double=$((size * 2))
    sips -z "$double" "$double" build/icon-1024.png --out "build/icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
  fi
done
cp build/icon-1024.png build/icon.iconset/icon_512x512@2x.png
iconutil -c icns build/icon.iconset -o build/CableLabelmaker.icns

.venv/bin/pyinstaller \
  --noconfirm \
  --clean \
  --windowed \
  --name "Cable Labelmaker" \
  --osx-bundle-identifier "io.github.twidtwid.cablelabel" \
  --icon build/CableLabelmaker.icns \
  --add-binary "$project_dir/bin/ptouch:bin" \
  --add-data "$project_dir/web:web" \
  --add-data "$project_dir/THIRD_PARTY_NOTICES.md:." \
  --add-data "$project_dir/${ptouch_license}:licenses" \
  --collect-all PIL \
  main.py

app_path="dist/Cable Labelmaker.app"
info_plist="$app_path/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$app_version" "$info_plist"
plutil -replace CFBundleVersion -string "$app_version" "$info_plist"

codesign --force --deep --sign - "$app_path"
zsh scripts/verify-macos-app.sh "$app_path" "$app_version"
echo "Built: $project_dir/$app_path"
