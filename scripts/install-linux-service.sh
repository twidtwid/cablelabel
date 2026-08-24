#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_name="$(basename "$0")"
bundle_source="$project_dir/dist/cablelabel"
trusted_origins=""
port="9462"
install_udev=1

usage() {
  echo "Usage: $script_name [--bundle PATH] [--port PORT] [--trusted-origin HTTPS_ORIGIN]... [--skip-udev]"
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}

validate_trusted_origin() {
  local origin="$1"
  local authority host origin_port label
  local -a labels

  [[ "$origin" == https://* ]] || return 1
  authority="${origin#https://}"
  authority="${authority%/}"
  [[ -n "$authority" ]] || return 1
  [[ "$authority" != */* && "$authority" != *\?* && "$authority" != *\#* ]] || return 1
  [[ "$authority" != *@* && "$authority" != *[[:space:]]* ]] || return 1

  if [[ "$authority" == *:* ]]; then
    host="${authority%:*}"
    origin_port="${authority##*:}"
    validate_port "$origin_port" || return 1
  else
    host="$authority"
  fi

  [[ -n "$host" && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
  IFS='.' read -r -a labels <<<"$host"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      bundle_source="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      validate_port "$2" || {
        echo "Port must be an integer from 1 to 65535." >&2
        exit 2
      }
      port="$2"
      shift 2
      ;;
    --trusted-origin)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      validate_trusted_origin "$2" || {
        echo "Trusted origins must be HTTPS origins with a valid host and no path, credentials, query, or fragment." >&2
        exit 2
      }
      trusted_origins="${trusted_origins:+$trusted_origins,}$2"
      shift 2
      ;;
    --skip-udev)
      install_udev=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || {
  echo "This script must run on Linux." >&2
  exit 1
}
command -v systemctl >/dev/null || {
  echo "systemd is required for persistent installation." >&2
  exit 1
}
[[ -x "$bundle_source/cablelabel" ]] || {
  echo "Linux bundle not found at $bundle_source. Run scripts/build-linux-app.sh first." >&2
  exit 1
}

version_file="$bundle_source/_internal/VERSION"
[[ -s "$version_file" ]] || {
  echo "Bundle version file is missing: $version_file" >&2
  exit 1
}
app_version="$(tr -d '[:space:]' <"$version_file")"
[[ "$app_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || {
  echo "Bundle version is invalid: $app_version" >&2
  exit 1
}

app_root="$HOME/.local/opt/cablelabel"
version_destination="$app_root/$app_version"
service_dir="$HOME/.config/systemd/user"
config_dir="$HOME/.config/cablelabel"
service_destination="$service_dir/cablelabel.service"
environment_file="$config_dir/environment"

install -d "$version_destination" "$service_dir" "$config_dir"
cp -a "$bundle_source/." "$version_destination/"
ln -sfn "$version_destination" "$app_root/current"
install -m 644 "$project_dir/linux/cablelabel.service" "$service_destination"
{
  printf 'CABLELABEL_PORT=%s\n' "$port"
  printf 'CABLELABEL_OPEN_BROWSER=0\n'
  printf 'CABLELABEL_TRUSTED_ORIGINS=%s\n' "$trusted_origins"
} >"$environment_file"
chmod 600 "$environment_file"

if (( install_udev )); then
  command -v udevadm >/dev/null || {
    echo "udevadm is required for PT-D600 USB permissions. Use --skip-udev only when permissions are already configured." >&2
    exit 1
  }
  command -v sudo >/dev/null || {
    echo "sudo is required to install the PT-D600 udev rule. Use --skip-udev only when permissions are already configured." >&2
    exit 1
  }
  sudo install -Dm644 "$project_dir/linux/70-cablelabel-pt-d600.rules" \
    /etc/udev/rules.d/70-cablelabel-pt-d600.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=04f9
fi

systemctl --user daemon-reload
systemctl --user enable --now cablelabel.service

health_url="http://127.0.0.1:$port/"
healthy=0
for _attempt in {1..20}; do
  if curl --fail --silent --connect-timeout 1 --max-time 2 "$health_url" >/dev/null; then
    healthy=1
    break
  fi
  sleep 1
done
if (( ! healthy )); then
  echo "Cable Labelmaker did not become healthy at $health_url" >&2
  systemctl --user status --no-pager cablelabel.service >&2 || true
  journalctl --user-unit cablelabel.service -n 40 --no-pager >&2 || true
  exit 1
fi

echo "Installed Cable Labelmaker $app_version at $health_url"
if [[ -n "$trusted_origins" ]]; then
  echo "Trusted remote origin(s): $trusted_origins"
else
  echo "Remote access is disabled; the app accepts localhost only."
fi
