#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
ptouch_version="0.5.0"
ptouch_url="https://github.com/vowstar/ptouch-rs/releases/download/v${ptouch_version}/ptouch-macos-arm64"
ptouch_sha="1645b7e985a4704ba74173acfff3a71ba0b0f3c6d01e99061003b3f956ee6fa1"
ptouch_license_url="https://raw.githubusercontent.com/vowstar/ptouch-rs/v${ptouch_version}/LICENSE"
ptouch_license_sha="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  local artifact_name="$4"

  if [[ -f "$destination" ]] && \
    [[ "$(shasum -a 256 "$destination" | awk '{print $1}')" == "$expected_sha" ]]; then
    return
  fi

  curl -fL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 \
    --retry-all-errors "$url" -o "$destination.download"
  local downloaded_sha
  downloaded_sha="$(shasum -a 256 "$destination.download" | awk '{print $1}')"
  if [[ "$downloaded_sha" != "$expected_sha" ]]; then
    echo "$artifact_name checksum mismatch" >&2
    exit 1
  fi
  mv "$destination.download" "$destination"
}

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
if [[ ! "$app_version" =~ '^[0-9]+([.][0-9]+){1,2}$' ]]; then
  echo "App version must contain two or three numeric components: $app_version" >&2
  exit 1
fi
mkdir -p bin build/icon.iconset build/licenses

download_verified "$ptouch_url" "$ptouch_sha" bin/ptouch "ptouch"
chmod 755 bin/ptouch

ptouch_license="build/licenses/ptouch-rs-GPL-3.0.txt"
download_verified \
  "$ptouch_license_url" \
  "$ptouch_license_sha" \
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
  --add-binary "bin/ptouch:bin" \
  --add-data "web:web" \
  --add-data "THIRD_PARTY_NOTICES.md:." \
  --add-data "${ptouch_license}:licenses" \
  --collect-all PIL \
  main.py

app_path="dist/Cable Labelmaker.app"
info_plist="$app_path/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$app_version" "$info_plist"
plutil -replace CFBundleVersion -string "$app_version" "$info_plist"

codesign --force --deep --sign - "$app_path"
zsh scripts/verify-macos-app.sh "$app_path" "$app_version"
echo "Built: $project_dir/$app_path"
