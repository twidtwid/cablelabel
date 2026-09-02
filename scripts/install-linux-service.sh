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
staged_version="$app_root/.${app_version}.install.$$"
backup_version="$app_root/.${app_version}.rollback.$$"
user_bin="$HOME/.local/bin"
service_dir="$HOME/.config/systemd/user"
config_dir="$HOME/.config/cablelabel"
service_destination="$service_dir/cablelabel.service"
environment_file="$config_dir/environment"
rendered_udev_rule="$config_dir/70-cablelabel-pt-d600.rules"
system_udev_rule="/etc/udev/rules.d/70-cablelabel-pt-d600.rules"
install_lock="$HOME/.cache/cablelabel/install.lock"
previous_current=""
install_succeeded=0
mutation_started=0
system_udev_rule_changed=0
version_destination_existed=0
previous_service_enabled=0
previous_service_active=0

mkdir -p "${install_lock%/*}"
lock_acquired=0
release_install_lock() {
  if (( lock_acquired )); then
    rm -f "$install_lock"
  fi
}
trap release_install_lock EXIT
create_install_lock() {
  (set -o noclobber; printf '%s\n' "$$" >"$install_lock") 2>/dev/null
}
if create_install_lock; then
  lock_acquired=1
else
  lock_owner="$(tr -d '[:space:]' <"$install_lock" 2>/dev/null || true)"
  if [[ "$lock_owner" =~ ^[0-9]+$ ]] && ! kill -0 "$lock_owner" 2>/dev/null; then
    stale_lock="${install_lock}.stale.$$"
    if mv "$install_lock" "$stale_lock" 2>/dev/null; then
      rm -rf "$stale_lock"
      if create_install_lock; then
        lock_acquired=1
      fi
    fi
  fi
fi
if (( ! lock_acquired )); then
  echo "Another Cable Labelmaker install is already running: $install_lock" >&2
  exit 1
fi
rollback_root="$(mktemp -d)"

if [[ -L "$app_root/current" ]]; then
  previous_current="$(readlink "$app_root/current")"
fi
[[ -e "$version_destination" ]] && version_destination_existed=1
[[ -f "$service_destination" ]] && cp -p "$service_destination" "$rollback_root/service"
[[ -f "$environment_file" ]] && cp -p "$environment_file" "$rollback_root/environment"
[[ -e "$user_bin/cablelabel" || -L "$user_bin/cablelabel" ]] && \
  cp -a "$user_bin/cablelabel" "$rollback_root/cli"
[[ -f "$rendered_udev_rule" ]] && \
  cp -p "$rendered_udev_rule" "$rollback_root/rendered-udev"
systemctl --user is-enabled --quiet cablelabel.service >/dev/null 2>&1 && \
  previous_service_enabled=1
systemctl --user is-active --quiet cablelabel.service >/dev/null 2>&1 && \
  previous_service_active=1

restore_path() {
  local backup="$1"
  local destination="$2"

  if [[ -e "$destination" || -L "$destination" ]]; then
    unlink "$destination"
  fi
  if [[ -e "$backup" || -L "$backup" ]]; then
    cp -a "$backup" "$destination"
  fi
}

rollback_failed=0
try_rollback() {
  local description="$1"
  shift

  if ! "$@"; then
    echo "Rollback failed while attempting to $description." >&2
    rollback_failed=1
  fi
}

finish_install() {
  local exit_code=$?
  set +e
  if (( ! install_succeeded && mutation_started )); then
    if [[ -n "$previous_current" ]]; then
      try_rollback "restore the current-version link" \
        ln -sfn "$previous_current" "$app_root/current"
    elif [[ -e "$app_root/current" || -L "$app_root/current" ]]; then
      try_rollback "remove the current-version link" unlink "$app_root/current"
    fi
    try_rollback "restore the CLI link" \
      restore_path "$rollback_root/cli" "$user_bin/cablelabel"
    try_rollback "restore the systemd service" \
      restore_path "$rollback_root/service" "$service_destination"
    try_rollback "restore the environment" \
      restore_path "$rollback_root/environment" "$environment_file"
    try_rollback "restore the rendered udev rule" \
      restore_path "$rollback_root/rendered-udev" "$rendered_udev_rule"
    if (( system_udev_rule_changed )); then
      if [[ -f "$rollback_root/system-udev" ]]; then
        try_rollback "restore the system udev rule" \
          sudo install -Dm644 "$rollback_root/system-udev" "$system_udev_rule"
      elif sudo test -e "$system_udev_rule"; then
        try_rollback "remove the system udev rule" sudo unlink "$system_udev_rule"
      fi
      try_rollback "reload udev rules" sudo udevadm control --reload-rules
      try_rollback "retrigger the Brother USB device" \
        sudo udevadm trigger --subsystem-match=usb --attr-match=idVendor=04f9 \
          --attr-match=idProduct=2074
    fi
    if [[ -e "$backup_version" ]]; then
      try_rollback "remove the failed version" rm -rf "$version_destination"
      try_rollback "restore the previous version" \
        mv "$backup_version" "$version_destination"
    elif (( ! version_destination_existed )) && \
      [[ -e "$version_destination" || -L "$version_destination" ]]; then
      try_rollback "remove the failed version" rm -rf "$version_destination"
    fi
    try_rollback "reload the user systemd manager" \
      systemctl --user daemon-reload
    if (( previous_service_enabled )); then
      try_rollback "re-enable the service" \
        systemctl --user enable cablelabel.service
    else
      try_rollback "restore the service's disabled state" \
        systemctl --user disable cablelabel.service
    fi
    if (( previous_service_active )); then
      try_rollback "restart the previous service" \
        systemctl --user restart cablelabel.service
    else
      try_rollback "restore the service's stopped state" \
        systemctl --user stop cablelabel.service
    fi
  fi
  if (( rollback_failed )); then
    rm -rf "$staged_version"
    echo "Cable Labelmaker rollback was incomplete; recovery files were preserved at:" >&2
    echo "  $rollback_root" >&2
    [[ -e "$backup_version" ]] && echo "  $backup_version" >&2
    release_install_lock
    return 1
  fi
  rm -rf "$staged_version" "$backup_version"
  if command -v trash >/dev/null; then
    trash "$rollback_root"
  else
    rm -rf "$rollback_root"
  fi
  release_install_lock
  return "$exit_code"
}
trap finish_install EXIT

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
  if sudo test -e "$system_udev_rule"; then
    sudo cp -p "$system_udev_rule" "$rollback_root/system-udev"
  fi
fi

mutation_started=1
install -d "$app_root" "$user_bin" "$service_dir" "$config_dir"
rm -rf "$staged_version" "$backup_version"
mkdir "$staged_version"
cp -a "$bundle_source/." "$staged_version/"
if [[ -e "$version_destination" ]]; then
  mv "$version_destination" "$backup_version"
fi
mv "$staged_version" "$version_destination"
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
  udev_rule="$(<"$udev_rule_template")"
  udev_rule="${udev_rule//@CABLELABEL_USER@/$service_user}"
  printf '%s\n' "$udev_rule" >"$rendered_udev_rule"
  chmod 644 "$rendered_udev_rule"
  system_udev_rule_changed=1
  sudo install -Dm644 "$rendered_udev_rule" \
    "$system_udev_rule"
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
