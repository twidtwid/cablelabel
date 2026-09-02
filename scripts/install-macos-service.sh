#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"
script_name="${0:t}"
app_source="$project_dir/dist/Cable Labelmaker.app"
applications_dir="${CABLELABEL_TEST_APPLICATIONS_DIR:-/Applications}"
app_destination="$applications_dir/Cable Labelmaker.app"
launchctl_bin="${CABLELABEL_TEST_LAUNCHCTL:-/bin/launchctl}"
service_label="io.github.twidtwid.cablelabel"
legacy_service_label="com.todd.cable-labelmaker"
installed_executable="$app_destination/Contents/MacOS/Cable Labelmaker"
launch_agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs"
launch_agent="$launch_agents/$service_label.plist"
legacy_launch_agent="$launch_agents/$legacy_service_label.plist"
template="$project_dir/macos/$service_label.plist"
domain="gui/$(id -u)"
trusted_origins=""
port="9462"

usage() {
  echo "Usage: $script_name [--app PATH] [--port PORT] [--trusted-origin HTTPS_ORIGIN]..."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      app_source="$2"
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

if [[ ! -d "$app_source" ]]; then
  echo "App not found at $app_source. Run scripts/build-mac-app.sh first." >&2
  exit 1
fi

source_info_plist="$app_source/Contents/Info.plist"
[[ -s "$source_info_plist" ]] || {
  echo "App Info.plist is missing: $source_info_plist" >&2
  exit 1
}
/usr/bin/plutil -lint "$source_info_plist" >/dev/null
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_info_plist")"
validate_app_version "$app_version" || {
  echo "App version is invalid: $app_version" >&2
  exit 1
}

user_bin="$HOME/.local/bin"
cli_link="$user_bin/cablelabel"
install_lock="$HOME/Library/Caches/CableLabel/install.lock"
staged_app="$applications_dir/.Cable Labelmaker.app.install.$$"
backup_app="$applications_dir/.Cable Labelmaker.app.rollback.$$"
install_succeeded=0
mutation_started=0
app_destination_existed=0
previous_service_loaded=0
previous_legacy_loaded=0
previous_service_disabled=0
previous_legacy_disabled=0
legacy_archived_path=""

mkdir -p "${install_lock:h}"
lock_acquired=0
release_install_lock() {
  if (( lock_acquired )); then
    /bin/rm -f "$install_lock"
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
  if [[ "$lock_owner" == <-> ]] && ! kill -0 "$lock_owner" 2>/dev/null; then
    stale_lock="${install_lock}.stale.$$"
    if /bin/mv "$install_lock" "$stale_lock" 2>/dev/null; then
      /bin/rm -rf "$stale_lock"
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

"$launchctl_bin" print "$domain/$service_label" >/dev/null 2>&1 && previous_service_loaded=1
"$launchctl_bin" print "$domain/$legacy_service_label" >/dev/null 2>&1 && previous_legacy_loaded=1
disabled_services="$("$launchctl_bin" print-disabled "$domain" 2>/dev/null || true)"
[[ -e "$app_destination" ]] && app_destination_existed=1
if print -r -- "$disabled_services" | /usr/bin/awk -v label="$service_label" '
  index($0, "\"" label "\" => true") { found = 1 }
  END { exit !found }
'; then
  previous_service_disabled=1
fi
if print -r -- "$disabled_services" | /usr/bin/awk -v label="$legacy_service_label" '
  index($0, "\"" label "\" => true") { found = 1 }
  END { exit !found }
'; then
  previous_legacy_disabled=1
fi
[[ -e "$launch_agent" || -L "$launch_agent" ]] && \
  /bin/cp -a "$launch_agent" "$rollback_root/launch-agent"
[[ -e "$cli_link" || -L "$cli_link" ]] && \
  /bin/cp -a "$cli_link" "$rollback_root/cli"

restore_path() {
  local backup="$1"
  local destination="$2"

  /bin/rm -rf "$destination"
  if [[ -e "$backup" || -L "$backup" ]]; then
    /bin/cp -a "$backup" "$destination"
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
    "$launchctl_bin" bootout "$domain/$service_label" >/dev/null 2>&1 || true
    if [[ -e "$backup_app" ]]; then
      try_rollback "remove the failed app" /bin/rm -rf "$app_destination"
      try_rollback "restore the previous app" /bin/mv "$backup_app" "$app_destination"
    elif (( ! app_destination_existed )) && \
      [[ -e "$app_destination" || -L "$app_destination" ]]; then
      try_rollback "remove the failed app" /bin/rm -rf "$app_destination"
    fi
    try_rollback "restore the LaunchAgent" \
      restore_path "$rollback_root/launch-agent" "$launch_agent"
    try_rollback "restore the CLI link" restore_path "$rollback_root/cli" "$cli_link"
    if [[ -n "$legacy_archived_path" && -e "$legacy_archived_path" && \
      ! -e "$legacy_launch_agent" ]]; then
      try_rollback "restore the legacy LaunchAgent" \
        /bin/mv "$legacy_archived_path" "$legacy_launch_agent"
    fi
    if (( previous_service_disabled )); then
      try_rollback "restore the service's disabled state" \
        "$launchctl_bin" disable "$domain/$service_label"
    else
      try_rollback "re-enable the service" \
        "$launchctl_bin" enable "$domain/$service_label"
      if (( previous_service_loaded )) && [[ -s "$launch_agent" ]]; then
        try_rollback "reload the previous service" \
          "$launchctl_bin" bootstrap "$domain" "$launch_agent"
      fi
    fi
    if (( previous_legacy_disabled )); then
      try_rollback "restore the legacy service's disabled state" \
        "$launchctl_bin" disable "$domain/$legacy_service_label"
    else
      try_rollback "re-enable the legacy service" \
        "$launchctl_bin" enable "$domain/$legacy_service_label"
      if (( previous_legacy_loaded )) && [[ -s "$legacy_launch_agent" ]]; then
        try_rollback "reload the previous legacy service" \
          "$launchctl_bin" bootstrap "$domain" "$legacy_launch_agent"
      fi
    fi
  fi
  if (( rollback_failed )); then
    /bin/rm -rf "$staged_app"
    echo "Cable Labelmaker rollback was incomplete; recovery files were preserved at:" >&2
    echo "  $rollback_root" >&2
    [[ -e "$backup_app" ]] && echo "  $backup_app" >&2
    release_install_lock
    return 1
  fi
  /bin/rm -rf "$staged_app" "$backup_app" "$rollback_root"
  release_install_lock
  return "$exit_code"
}
trap finish_install EXIT

mutation_started=1
"$launchctl_bin" bootout "$domain/$service_label" 2>/dev/null || true
"$launchctl_bin" bootout "$domain/$legacy_service_label" 2>/dev/null || true
"$launchctl_bin" disable "$domain/$legacy_service_label" 2>/dev/null || true
if /usr/bin/pgrep -f -x "$installed_executable" >/dev/null 2>&1; then
  /usr/bin/pkill -TERM -f -x "$installed_executable"
  for _attempt in {1..50}; do
    if ! /usr/bin/pgrep -f -x "$installed_executable" >/dev/null 2>&1; then
      break
    fi
    /bin/sleep 0.1
  done
  if /usr/bin/pgrep -f -x "$installed_executable" >/dev/null 2>&1; then
    echo "The previous Cable Labelmaker process did not stop." >&2
    exit 1
  fi
fi

if [[ "$app_source" != "$app_destination" ]]; then
  /bin/rm -rf "$staged_app" "$backup_app"
  /usr/bin/ditto "$app_source" "$staged_app"
  if [[ -e "$app_destination" ]]; then
    /bin/mv "$app_destination" "$backup_app"
  fi
  /bin/mv "$staged_app" "$app_destination"
fi

mkdir -p "$user_bin"
ln -sfn "$app_destination/Contents/MacOS/Cable Labelmaker" "$cli_link"

mkdir -p "$launch_agents" "$logs"
/usr/bin/ditto "$template" "$launch_agent"
/usr/bin/plutil -replace EnvironmentVariables.CABLELABEL_PORT \
  -string "$port" "$launch_agent"
/usr/bin/plutil -replace EnvironmentVariables.CABLELABEL_TRUSTED_ORIGINS \
  -string "$trusted_origins" "$launch_agent"
/usr/bin/plutil -replace StandardOutPath -string "$logs/cablelabel.out.log" "$launch_agent"
/usr/bin/plutil -replace StandardErrorPath -string "$logs/cablelabel.err.log" "$launch_agent"
/usr/bin/plutil -lint "$launch_agent" >/dev/null

"$launchctl_bin" enable "$domain/$service_label"
"$launchctl_bin" bootstrap "$domain" "$launch_agent"

health_url="http://127.0.0.1:$port/api/health"
expected_health="{\"name\": \"cablelabel\", \"version\": \"$app_version\"}"
if ! wait_for_http_body "$health_url" "$expected_health" ||
  ! "$launchctl_bin" print "$domain/$service_label" 2>/dev/null | /usr/bin/awk '
    $1 == "state" && $2 == "=" && $3 == "running" { found = 1 }
    END { exit !found }
  '; then
  echo "Cable Labelmaker did not become healthy at $health_url" >&2
  /usr/bin/curl --fail --silent --show-error --connect-timeout 1 --max-time 2 \
    "$health_url" >/dev/null || true
  echo "LaunchAgent state:" >&2
  "$launchctl_bin" print "$domain/$service_label" >&2 || true
  if [[ -f "$logs/cablelabel.err.log" ]]; then
    echo "Recent Cable Labelmaker errors:" >&2
    /usr/bin/tail -n 40 "$logs/cablelabel.err.log" >&2
  fi
  exit 1
fi

if [[ -e "$legacy_launch_agent" || -L "$legacy_launch_agent" ]]; then
  legacy_archive="$launch_agents/Archived"
  mkdir -p "$legacy_archive"
  legacy_archived_path="$legacy_archive/$legacy_service_label.plist.$(/bin/date +%Y%m%d-%H%M%S)"
  /bin/mv "$legacy_launch_agent" "$legacy_archived_path"
fi

install_succeeded=1
app_url="http://127.0.0.1:$port/"
echo "Installed Cable Labelmaker $app_version and started $service_label at $app_url"
if [[ -n "$trusted_origins" ]]; then
  echo "Trusted remote origin(s): $trusted_origins"
else
  echo "Remote access is disabled; the app accepts localhost only."
fi
