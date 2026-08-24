#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"
script_name="${0:t}"
app_source="$project_dir/dist/Cable Labelmaker.app"
app_destination="/Applications/Cable Labelmaker.app"
service_label="io.github.twidtwid.cablelabel"
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

if [[ "$app_source" != "$app_destination" ]]; then
  /usr/bin/ditto "$app_source" "$app_destination"
fi

user_bin="$HOME/.local/bin"
mkdir -p "$user_bin"
ln -sfn "$app_destination/Contents/MacOS/Cable Labelmaker" "$user_bin/cablelabel"

launch_agents="$HOME/Library/LaunchAgents"
logs="$HOME/Library/Logs"
launch_agent="$launch_agents/$service_label.plist"
template="$project_dir/macos/$service_label.plist"
domain="gui/$(id -u)"

mkdir -p "$launch_agents" "$logs"
/usr/bin/ditto "$template" "$launch_agent"
/usr/bin/plutil -replace EnvironmentVariables.CABLELABEL_PORT \
  -string "$port" "$launch_agent"
/usr/bin/plutil -replace EnvironmentVariables.CABLELABEL_TRUSTED_ORIGINS \
  -string "$trusted_origins" "$launch_agent"
/usr/bin/plutil -replace StandardOutPath -string "$logs/cablelabel.out.log" "$launch_agent"
/usr/bin/plutil -replace StandardErrorPath -string "$logs/cablelabel.err.log" "$launch_agent"
/usr/bin/plutil -lint "$launch_agent" >/dev/null

/bin/launchctl bootout "$domain/$service_label" 2>/dev/null || true
/bin/launchctl enable "$domain/$service_label"
/bin/launchctl bootstrap "$domain" "$launch_agent"

health_url="http://127.0.0.1:$port/"
if ! wait_for_http "$health_url"; then
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

echo "Installed Cable Labelmaker and started $service_label at $health_url"
if [[ -n "$trusted_origins" ]]; then
  echo "Trusted remote origin(s): $trusted_origins"
else
  echo "Remote access is disabled; the app accepts localhost only."
fi
