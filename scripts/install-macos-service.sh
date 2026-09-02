#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"
script_name="${0:t}"
app_source="$project_dir/dist/Cable Labelmaker.app"
app_destination="/Applications/Cable Labelmaker.app"
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
rollback_root="$(mktemp -d)"
staged_app="/Applications/.Cable Labelmaker.app.install.$$"
backup_app="/Applications/.Cable Labelmaker.app.rollback.$$"
install_succeeded=0
app_replaced=0
previous_service_loaded=0
previous_legacy_loaded=0

/bin/launchctl print "$domain/$service_label" >/dev/null 2>&1 && previous_service_loaded=1
/bin/launchctl print "$domain/$legacy_service_label" >/dev/null 2>&1 && previous_legacy_loaded=1
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

finish_install() {
  local exit_code=$?
  set +e
  if (( ! install_succeeded )); then
    /bin/launchctl bootout "$domain/$service_label" >/dev/null 2>&1 || true
    if (( app_replaced )); then
      /bin/rm -rf "$app_destination"
      [[ -e "$backup_app" ]] && /bin/mv "$backup_app" "$app_destination"
    fi
    restore_path "$rollback_root/launch-agent" "$launch_agent"
    restore_path "$rollback_root/cli" "$cli_link"
    if (( previous_service_loaded )) && [[ -s "$launch_agent" ]]; then
      /bin/launchctl enable "$domain/$service_label" >/dev/null 2>&1 || true
      /bin/launchctl bootstrap "$domain" "$launch_agent" >/dev/null 2>&1 || true
    else
      /bin/launchctl disable "$domain/$service_label" >/dev/null 2>&1 || true
    fi
    if (( previous_legacy_loaded )) && [[ -s "$legacy_launch_agent" ]]; then
      /bin/launchctl enable "$domain/$legacy_service_label" >/dev/null 2>&1 || true
      /bin/launchctl bootstrap "$domain" "$legacy_launch_agent" >/dev/null 2>&1 || true
    fi
  fi
  /bin/rm -rf "$staged_app" "$backup_app" "$rollback_root"
  return "$exit_code"
}
trap finish_install EXIT

/bin/launchctl bootout "$domain/$service_label" 2>/dev/null || true
/bin/launchctl bootout "$domain/$legacy_service_label" 2>/dev/null || true
/bin/launchctl disable "$domain/$legacy_service_label" 2>/dev/null || true
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
  app_replaced=1
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

/bin/launchctl enable "$domain/$service_label"
/bin/launchctl bootstrap "$domain" "$launch_agent"

health_url="http://127.0.0.1:$port/api/health"
expected_health="{\"name\": \"cablelabel\", \"version\": \"$app_version\"}"
if ! wait_for_http_body "$health_url" "$expected_health" ||
  ! /bin/launchctl print "$domain/$service_label" 2>/dev/null | /usr/bin/awk '
    $1 == "state" && $2 == "=" && $3 == "running" { found = 1 }
    END { exit !found }
  '; then
  echo "Cable Labelmaker did not become healthy at $health_url" >&2
  /usr/bin/curl --fail --silent --show-error --connect-timeout 1 --max-time 2 \
    "$health_url" >/dev/null || true
  echo "LaunchAgent state:" >&2
  /bin/launchctl print "$domain/$service_label" >&2 || true
  if [[ -f "$logs/cablelabel.err.log" ]]; then
    echo "Recent Cable Labelmaker errors:" >&2
    /usr/bin/tail -n 40 "$logs/cablelabel.err.log" >&2
  fi
  exit 1
fi

if [[ -e "$legacy_launch_agent" || -L "$legacy_launch_agent" ]]; then
  legacy_archive="$launch_agents/Archived"
  mkdir -p "$legacy_archive"
  /bin/mv "$legacy_launch_agent" \
    "$legacy_archive/$legacy_service_label.plist.$(/bin/date +%Y%m%d-%H%M%S)"
fi

install_succeeded=1
app_url="http://127.0.0.1:$port/"
echo "Installed Cable Labelmaker $app_version and started $service_label at $app_url"
if [[ -n "$trusted_origins" ]]; then
  echo "Trusted remote origin(s): $trusted_origins"
else
  echo "Remote access is disabled; the app accepts localhost only."
fi
