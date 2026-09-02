#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
test_root="$(mktemp -d)"

cleanup() {
  if command -v trash >/dev/null; then
    trash "$test_root"
  else
    /bin/rm -rf "$test_root"
  fi
}
trap cleanup EXIT

fake_bin="$test_root/bin"
fake_launchctl="$fake_bin/launchctl"
state_dir="$test_root/launchctl-state"
log_file="$test_root/launchctl.log"
applications_dir="$test_root/Applications"
test_home="$test_root/home"
source_app="$test_root/Source.app"
service_label="io.github.twidtwid.cablelabel"
legacy_label="com.todd.cable-labelmaker"
mkdir -p "$fake_bin" "$state_dir" "$applications_dir" \
  "$source_app/Contents/MacOS" "$test_home"

/usr/bin/plutil -create xml1 "$source_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.3.1' \
  "$source_app/Contents/Info.plist"
printf '#!/bin/zsh\nexit 0\n' >"$source_app/Contents/MacOS/Cable Labelmaker"
chmod +x "$source_app/Contents/MacOS/Cable Labelmaker"
printf 'new app\n' >"$source_app/new-marker"

cat >"$fake_launchctl" <<'EOF'
#!/bin/zsh
set -u

command="$1"
shift
printf '%s %s\n' "$command" "$*" >>"$TEST_LAUNCHCTL_LOG"

label_from_target() {
  print -r -- "${1##*/}"
}

case "$command" in
  print)
    label="$(label_from_target "$1")"
    [[ -e "$TEST_LAUNCHCTL_STATE/loaded-$label" ]] || exit 1
    print 'state = running'
    ;;
  print-disabled)
    print 'disabled services = {'
    for marker in "$TEST_LAUNCHCTL_STATE"/disabled-*; do
      [[ -e "$marker" ]] || continue
      label="${marker##*/disabled-}"
      print "\"$label\" => true"
    done
    print '}'
    ;;
  bootout)
    label="$(label_from_target "$1")"
    /bin/rm -f "$TEST_LAUNCHCTL_STATE/loaded-$label"
    ;;
  disable)
    label="$(label_from_target "$1")"
    : >"$TEST_LAUNCHCTL_STATE/disabled-$label"
    ;;
  enable)
    label="$(label_from_target "$1")"
    /bin/rm -f "$TEST_LAUNCHCTL_STATE/disabled-$label"
    ;;
  bootstrap)
    plist="$2"
    label="${plist:t:r}"
    if [[ "$label" == "io.github.twidtwid.cablelabel" && \
      -n "${TEST_FAIL_BOOTSTRAP_ONCE:-}" && \
      ! -e "$TEST_FAIL_BOOTSTRAP_ONCE" ]]; then
      : >"$TEST_FAIL_BOOTSTRAP_ONCE"
      exit 1
    fi
    : >"$TEST_LAUNCHCTL_STATE/loaded-$label"
    ;;
esac
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/bin/zsh
printf '{"name": "cablelabel", "version": "%s"}' "$TEST_HEALTH_VERSION"
EOF
chmod +x "$fake_launchctl" "$fake_bin/curl"

reset_fixture() {
  /bin/rm -rf "$applications_dir" "$test_home" "$state_dir"
  mkdir -p "$applications_dir" "$test_home/Library/LaunchAgents" \
    "$test_home/.local/bin" "$state_dir"
  : >"$log_file"
}

run_installer() {
  local failure_marker="${1:-}"

  HOME="$test_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    CABLELABEL_TEST_APPLICATIONS_DIR="$applications_dir" \
    CABLELABEL_TEST_LAUNCHCTL="$fake_launchctl" \
    TEST_LAUNCHCTL_LOG="$log_file" \
    TEST_LAUNCHCTL_STATE="$state_dir" \
    TEST_FAIL_BOOTSTRAP_ONCE="$failure_marker" \
    TEST_HEALTH_VERSION="0.3.1" \
    "$project_dir/scripts/install-macos-service.sh" --app "$source_app"
}

reset_fixture
mkdir -p "$test_home/Library/Caches/CableLabel"
printf '%s\n' "$$" >"$test_home/Library/Caches/CableLabel/install.lock"
if run_installer >"$test_root/concurrent.out" 2>&1; then
  echo "macOS installer accepted a concurrent invocation" >&2
  exit 1
fi
[[ ! -e "$applications_dir/Cable Labelmaker.app" ]]
[[ ! -s "$log_file" ]]
/bin/rm -f "$test_home/Library/Caches/CableLabel/install.lock"

reset_fixture
mkdir -p "$applications_dir/Cable Labelmaker.app"
printf 'old app\n' >"$applications_dir/Cable Labelmaker.app/old-marker"
printf 'old launch agent\n' >"$test_home/Library/LaunchAgents/$service_label.plist"
ln -s /old/cablelabel "$test_home/.local/bin/cablelabel"
printf 'legacy launch agent\n' >"$test_home/Library/LaunchAgents/$legacy_label.plist"
: >"$state_dir/loaded-$service_label"
: >"$state_dir/loaded-$legacy_label"
failure_marker="$test_root/upgrade-bootstrap-failed"
if run_installer "$failure_marker" >"$test_root/upgrade.out" 2>&1; then
  echo "macOS installer accepted an injected upgrade failure" >&2
  exit 1
fi
[[ -f "$applications_dir/Cable Labelmaker.app/old-marker" ]]
[[ ! -e "$applications_dir/Cable Labelmaker.app/new-marker" ]]
[[ "$(<"$test_home/Library/LaunchAgents/$service_label.plist")" == \
  "old launch agent" ]]
[[ "$(readlink "$test_home/.local/bin/cablelabel")" == "/old/cablelabel" ]]
[[ -e "$state_dir/loaded-$service_label" ]]
[[ -e "$state_dir/loaded-$legacy_label" ]]
[[ ! -e "$state_dir/disabled-$service_label" ]]
[[ ! -e "$state_dir/disabled-$legacy_label" ]]

reset_fixture
mkdir -p "$test_home/Library/Caches/CableLabel"
printf '99999999\n' >"$test_home/Library/Caches/CableLabel/install.lock"
failure_marker="$test_root/fresh-bootstrap-failed"
if run_installer "$failure_marker" >"$test_root/fresh.out" 2>&1; then
  echo "macOS installer accepted an injected fresh-install failure" >&2
  exit 1
fi
[[ ! -e "$applications_dir/Cable Labelmaker.app" ]]
[[ ! -e "$test_home/Library/LaunchAgents/$service_label.plist" ]]
[[ ! -e "$test_home/.local/bin/cablelabel" ]]
[[ ! -e "$state_dir/loaded-$service_label" ]]
[[ ! -e "$state_dir/disabled-$service_label" ]]
[[ ! -e "$test_home/Library/Caches/CableLabel/install.lock" ]]

reset_fixture
printf 'legacy launch agent\n' >"$test_home/Library/LaunchAgents/$legacy_label.plist"
: >"$state_dir/loaded-$legacy_label"
run_installer >"$test_root/success.out" 2>&1
[[ -f "$applications_dir/Cable Labelmaker.app/new-marker" ]]
[[ -L "$test_home/.local/bin/cablelabel" ]]
[[ -e "$state_dir/loaded-$service_label" ]]
[[ ! -e "$test_home/Library/LaunchAgents/$legacy_label.plist" ]]
archived=("$test_home/Library/LaunchAgents/Archived/$legacy_label.plist."*)
[[ ${#archived[@]} -eq 1 && -f "$archived[1]" ]]
[[ -e "$state_dir/disabled-$legacy_label" ]]

echo "macOS installer transaction tests passed"
