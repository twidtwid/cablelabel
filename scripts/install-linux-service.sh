#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"
script_name="$(basename "$0")"
bundle_source="$project_dir/dist/cablelabel"
trusted_origins=""
port="9462"
install_udev=1
verify_only=0

usage() {
  echo "Usage: $script_name [--bundle PATH] [--port PORT] [--trusted-origin HTTPS_ORIGIN]... [--skip-udev] [--verify-only]"
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
    --verify-only)
      verify_only=1
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

[[ -x "$bundle_source/cablelabel" ]] || {
  echo "Linux bundle not found at $bundle_source. Run scripts/build-linux-app.sh first." >&2
  exit 1
}

service_template="$project_dir/linux/cablelabel.service"
udev_rule_template="$project_dir/linux/70-cablelabel-pt-d600.rules"
[[ -s "$service_template" ]] || {
  echo "systemd service template is missing: $service_template" >&2
  exit 1
}
if (( install_udev )) && [[ ! -s "$udev_rule_template" ]]; then
  echo "PT-D600 udev rule template is missing: $udev_rule_template" >&2
  exit 1
fi

version_file="$bundle_source/_internal/VERSION"
[[ -s "$version_file" ]] || {
  echo "Bundle version file is missing: $version_file" >&2
  exit 1
}
app_version="$(tr -d '[:space:]' <"$version_file")"
validate_app_version "$app_version" || {
  echo "Bundle version is invalid: $app_version" >&2
  exit 1
}

if (( verify_only )); then
  echo "Verified Linux installer bundle: $bundle_source (version $app_version)"
  exit 0
fi

[[ "$(uname -s)" == "Linux" ]] || {
  echo "This script must run on Linux." >&2
  exit 1
}
command -v systemctl >/dev/null || {
  echo "systemd is required for persistent installation." >&2
  exit 1
}

app_root="$HOME/.local/opt/cablelabel"
version_destination="$app_root/$app_version"
user_bin="$HOME/.local/bin"
service_dir="$HOME/.config/systemd/user"
config_dir="$HOME/.config/cablelabel"
service_destination="$service_dir/cablelabel.service"
environment_file="$config_dir/environment"
rendered_udev_rule="$config_dir/70-cablelabel-pt-d600.rules"
previous_current=""
rollback_root="$(mktemp -d)"
install_succeeded=0
version_destination_existed=0

if [[ -L "$app_root/current" ]]; then
  previous_current="$(readlink "$app_root/current")"
fi
[[ -f "$service_destination" ]] && cp -p "$service_destination" "$rollback_root/service"
[[ -f "$environment_file" ]] && cp -p "$environment_file" "$rollback_root/environment"
[[ -e "$user_bin/cablelabel" || -L "$user_bin/cablelabel" ]] && \
  cp -a "$user_bin/cablelabel" "$rollback_root/cli"
[[ -f "$rendered_udev_rule" ]] && \
  cp -p "$rendered_udev_rule" "$rollback_root/rendered-udev"
[[ -e "$version_destination" ]] && version_destination_existed=1

restore_path() {
  local backup="$1"
  local destination="$2"

  if [[ -e "$destination" || -L "$destination" ]]; then
    unlink "$destination" 2>/dev/null || true
  fi
  if [[ -e "$backup" || -L "$backup" ]]; then
    cp -a "$backup" "$destination"
  fi
}

finish_install() {
  local exit_code=$?
  set +e
  if (( ! install_succeeded )); then
    if [[ -n "$previous_current" ]]; then
      ln -sfn "$previous_current" "$app_root/current"
    else
      unlink "$app_root/current" 2>/dev/null || true
    fi
    restore_path "$rollback_root/cli" "$user_bin/cablelabel"
    restore_path "$rollback_root/service" "$service_destination"
    restore_path "$rollback_root/environment" "$environment_file"
    restore_path "$rollback_root/rendered-udev" "$rendered_udev_rule"
    if (( ! version_destination_existed )); then
      rm -rf "$version_destination"
    fi
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if [[ -n "$previous_current" ]]; then
      systemctl --user restart cablelabel.service >/dev/null 2>&1 || true
    else
      systemctl --user stop cablelabel.service >/dev/null 2>&1 || true
      systemctl --user disable cablelabel.service >/dev/null 2>&1 || true
    fi
  fi
  if command -v trash >/dev/null; then
    trash "$rollback_root"
  else
    rm -rf "$rollback_root"
  fi
  return "$exit_code"
}
trap finish_install EXIT

install -d "$version_destination" "$user_bin" "$service_dir" "$config_dir"
cp -a "$bundle_source/." "$version_destination/"
ln -sfn "$version_destination" "$app_root/current"
ln -sfn "$app_root/current/cablelabel" "$user_bin/cablelabel"
install -m 644 "$service_template" "$service_destination"
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
  service_user="$(id -un)"
  validate_service_username "$service_user" || {
    echo "Cannot install the PT-D600 udev rule for invalid service user: $service_user" >&2
    exit 1
  }
  udev_rule="$(<"$udev_rule_template")"
  udev_rule="${udev_rule//@CABLELABEL_USER@/$service_user}"
  printf '%s\n' "$udev_rule" >"$rendered_udev_rule"
  chmod 644 "$rendered_udev_rule"
  sudo install -Dm644 "$rendered_udev_rule" \
    /etc/udev/rules.d/70-cablelabel-pt-d600.rules
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=04f9 \
    --attr-match=idProduct=2074
fi

systemctl --user daemon-reload
systemctl --user enable cablelabel.service
systemctl --user restart cablelabel.service

app_url="http://127.0.0.1:$port/"
health_url="${app_url}api/health"
expected_health="{\"name\": \"cablelabel\", \"version\": \"$app_version\"}"
if ! wait_for_http_body "$health_url" "$expected_health" ||
  ! systemctl --user is-active --quiet cablelabel.service; then
  echo "Cable Labelmaker did not become healthy at $health_url" >&2
  systemctl --user status --no-pager cablelabel.service >&2 || true
  journalctl --user-unit cablelabel.service -n 40 --no-pager >&2 || true
  exit 1
fi

install_succeeded=1
echo "Installed Cable Labelmaker $app_version at $app_url"
if [[ -n "$trusted_origins" ]]; then
  echo "Trusted remote origin(s): $trusted_origins"
else
  echo "Remote access is disabled; the app accepts localhost only."
fi
