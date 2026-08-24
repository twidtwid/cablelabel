#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"

build_arm64_ptouch() {
  local source_url="https://github.com/vowstar/ptouch-rs/archive/refs/tags/v${PTOUCH_VERSION}.tar.gz"
  local source_sha="5d4700c8e24081a33bd885fb0ad2b53e670bf2a9b0f921a6c39a8551518bcad5"
  local source_archive="build/ptouch-rs-v${PTOUCH_VERSION}.tar.gz"
  local source_dir="build/ptouch-rs-${PTOUCH_VERSION}"

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
      "https://github.com/vowstar/ptouch-rs/releases/download/v${PTOUCH_VERSION}/ptouch-linux-amd64" \
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
  "$PTOUCH_LICENSE_URL" \
  "$PTOUCH_LICENSE_SHA" \
  "$ptouch_license" \
  "ptouch license"

if [[ ! -x .venv/bin/python ]]; then
  "$uv_bin" venv --python 3.12 .venv
fi
"$uv_bin" pip install --python .venv/bin/python -r requirements.txt -r requirements-build.txt

app_version="$(.venv/bin/python -c 'from cable_labelmaker import __version__; print(__version__)')"
if ! validate_app_version "$app_version"; then
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
