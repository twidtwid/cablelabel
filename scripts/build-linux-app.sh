#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ptouch_version="0.5.0"
ptouch_license_url="https://raw.githubusercontent.com/vowstar/ptouch-rs/v${ptouch_version}/LICENSE"
ptouch_license_sha="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  local artifact_name="$4"

  if [[ -f "$destination" ]] &&
    [[ "$(sha256sum "$destination" | awk '{print $1}')" == "$expected_sha" ]]; then
    return
  fi

  curl -fL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 \
    --retry-all-errors "$url" -o "$destination.download"
  local downloaded_sha
  downloaded_sha="$(sha256sum "$destination.download" | awk '{print $1}')"
  if [[ "$downloaded_sha" != "$expected_sha" ]]; then
    echo "$artifact_name checksum mismatch" >&2
    exit 1
  fi
  mv "$destination.download" "$destination"
}

build_arm64_ptouch() {
  local source_url="https://github.com/vowstar/ptouch-rs/archive/refs/tags/v${ptouch_version}.tar.gz"
  local source_sha="5d4700c8e24081a33bd885fb0ad2b53e670bf2a9b0f921a6c39a8551518bcad5"
  local source_archive="build/ptouch-rs-v${ptouch_version}.tar.gz"
  local source_dir="build/ptouch-rs-${ptouch_version}"

  command -v cargo >/dev/null || {
    echo "Rust is required to build ptouch-rs on Linux arm64." >&2
    exit 1
  }
  if ! command -v pkg-config >/dev/null || ! pkg-config --exists libudev; then
    echo "libudev development files are required to build ptouch-rs on Linux arm64." >&2
    exit 1
  fi

  download_verified "$source_url" "$source_sha" "$source_archive" "ptouch source"
  if [[ ! -d "$source_dir" ]]; then
    tar -xzf "$source_archive" -C build
  fi
  cargo build \
    --manifest-path "$source_dir/Cargo.toml" \
    --locked \
    --release \
    --package ptouch-cli
  cp "$source_dir/target/release/ptouch" bin/ptouch
}

cd "$project_dir"

[[ "$(uname -s)" == "Linux" ]] || {
  echo "This script must run on Linux." >&2
  exit 1
}

uv_bin="$(command -v uv || true)"
if [[ -z "$uv_bin" ]]; then
  echo "uv is required. Install it from https://docs.astral.sh/uv/." >&2
  exit 1
fi

mkdir -p bin build/licenses
case "$(uname -m)" in
  x86_64)
    download_verified \
      "https://github.com/vowstar/ptouch-rs/releases/download/v${ptouch_version}/ptouch-linux-amd64" \
      "8e5ec4de0b7b7736879dbc21d42aa7abc191bc3a7839d0f4f12cd70aa70d39cd" \
      bin/ptouch \
      "ptouch"
    ;;
  aarch64|arm64)
    build_arm64_ptouch
    ;;
  *)
    echo "Unsupported Linux architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
chmod 755 bin/ptouch

ptouch_license="build/licenses/ptouch-rs-GPL-3.0.txt"
download_verified \
  "$ptouch_license_url" \
  "$ptouch_license_sha" \
  "$ptouch_license" \
  "ptouch license"

if [[ ! -x .venv/bin/python ]]; then
  "$uv_bin" venv --python 3.12 .venv
fi
"$uv_bin" pip install --python .venv/bin/python -r requirements.txt -r requirements-build.txt

app_version="$(.venv/bin/python -c 'from cable_labelmaker import __version__; print(__version__)')"
if [[ ! "$app_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "App version must contain two or three numeric components: $app_version" >&2
  exit 1
fi
printf '%s\n' "$app_version" >build/VERSION

.venv/bin/pyinstaller \
  --noconfirm \
  --clean \
  --name cablelabel \
  --add-binary "bin/ptouch:bin" \
  --add-data "web:web" \
  --add-data "THIRD_PARTY_NOTICES.md:." \
  --add-data "${ptouch_license}:licenses" \
  --add-data "build/VERSION:." \
  --collect-all PIL \
  main.py

scripts/verify-linux-app.sh dist/cablelabel "$app_version"
echo "Built: $project_dir/dist/cablelabel"
