#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"

cleanup() {
  if command -v trash >/dev/null; then
    trash "$test_root"
  else
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

fake_bin="$test_root/bin"
test_home="$test_root/home"
systemctl_log="$test_root/systemctl.log"
systemctl_state="$test_root/systemctl-state"
sudo_log="$test_root/sudo.log"
installed_udev_rule="$test_root/installed.rules"
system_udev_rule="$test_root/system.rules"
mkdir -p "$fake_bin" "$test_home" "$systemctl_state"

cat >"$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

cat >"$fake_bin/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-un" ]] || exit 2
printf '%s\n' "$TEST_SERVICE_USER"
EOF

cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "--user is-active --quiet cablelabel.service" ]]; then
  [[ -e "$TEST_SYSTEMCTL_STATE/active" ]]
  exit
fi
if [[ "$*" == "--user is-enabled --quiet cablelabel.service" ]]; then
  [[ -e "$TEST_SYSTEMCTL_STATE/enabled" ]]
  exit
fi
if [[ "$*" == "--user restart cablelabel.service" && -n "${TEST_FAIL_RESTART_ONCE:-}" && ! -e "$TEST_FAIL_RESTART_ONCE" ]]; then
  : >"$TEST_FAIL_RESTART_ONCE"
  exit 1
fi
if [[ "$*" == "--user enable cablelabel.service" && -n "${TEST_FAIL_ENABLE_ONCE:-}" && ! -e "$TEST_FAIL_ENABLE_ONCE" ]]; then
  : >"$TEST_FAIL_ENABLE_ONCE"
  exit 1
fi
printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
case "$*" in
  "--user enable cablelabel.service") : >"$TEST_SYSTEMCTL_STATE/enabled" ;;
  "--user disable cablelabel.service") rm -f "$TEST_SYSTEMCTL_STATE/enabled" ;;
  "--user restart cablelabel.service"|"--user start cablelabel.service")
    : >"$TEST_SYSTEMCTL_STATE/active"
    ;;
  "--user stop cablelabel.service") rm -f "$TEST_SYSTEMCTL_STATE/active" ;;
esac
EOF

cat >"$fake_bin/udevadm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SUDO_LOG"
case "$1" in
  test)
    [[ -e "$TEST_SYSTEM_UDEV_RULE" ]]
    ;;
  cp)
    cp "$TEST_SYSTEM_UDEV_RULE" "$4"
    ;;
  install)
    if [[ "$3" == */system-udev && \
      -n "${TEST_FAIL_ROLLBACK_INSTALL_ONCE:-}" && \
      ! -e "$TEST_FAIL_ROLLBACK_INSTALL_ONCE" ]]; then
      : >"$TEST_FAIL_ROLLBACK_INSTALL_ONCE"
      exit 1
    fi
    cp "$3" "$TEST_INSTALLED_UDEV_RULE"
    cp "$3" "$TEST_SYSTEM_UDEV_RULE"
    if [[ -n "${TEST_FAIL_SUDO_INSTALL_AFTER_WRITE_ONCE:-}" && ! -e "$TEST_FAIL_SUDO_INSTALL_AFTER_WRITE_ONCE" ]]; then
      : >"$TEST_FAIL_SUDO_INSTALL_AFTER_WRITE_ONCE"
      exit 1
    fi
    ;;
  unlink)
    unlink "$TEST_SYSTEM_UDEV_RULE"
    ;;
  udevadm)
    operation="${2:-}"
    marker=""
    case "$operation" in
      control) marker="${TEST_FAIL_UDEV_RELOAD_ONCE:-}" ;;
      trigger) marker="${TEST_FAIL_UDEV_TRIGGER_ONCE:-}" ;;
    esac
    if [[ -n "$marker" && ! -e "$marker" ]]; then
      : >"$marker"
      exit 1
    fi
    ;;
esac
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"name": "cablelabel", "version": "%s"}' "$TEST_HEALTH_VERSION"
EOF

chmod +x "$fake_bin"/*

make_bundle() {
  local bundle="$1"
  local version="$2"

  mkdir -p "$bundle/_internal"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/cablelabel"
  chmod +x "$bundle/cablelabel"
  printf '%s\n' "$version" >"$bundle/_internal/VERSION"
}

assert_service_sequence() {
  local phase="$1"
  local expected
  local actual

  expected=$'--user daemon-reload\n--user enable cablelabel.service\n--user restart cablelabel.service'
  actual="$(<"$systemctl_log")"
  [[ "$actual" == "$expected" ]] || {
    echo "Unexpected systemctl sequence during $phase:" >&2
    printf '%s\n' "$actual" >&2
    exit 1
  }
}

run_installer() {
  local bundle="$1"
  local version

  version="$(tr -d '[:space:]' <"$bundle/_internal/VERSION")"

  : >"$systemctl_log"
  HOME="$test_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    TEST_SERVICE_USER="cablelabel_tester" \
    TEST_SYSTEMCTL_LOG="$systemctl_log" \
    TEST_SYSTEMCTL_STATE="$systemctl_state" \
    TEST_SUDO_LOG="$sudo_log" \
    TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
    TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
    TEST_HEALTH_VERSION="$version" \
    "$project_dir/scripts/install-linux-service.sh" --bundle "$bundle"
}

first_bundle="$test_root/bundle-0.2.0"
upgrade_bundle="$test_root/bundle-0.2.1"
make_bundle "$first_bundle" 0.2.0
make_bundle "$upgrade_bundle" 0.2.1

mkdir -p "$test_home/.cache/cablelabel"
printf '%s\n' "$$" >"$test_home/.cache/cablelabel/install.lock"
: >"$systemctl_log"
: >"$sudo_log"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  TEST_HEALTH_VERSION="0.2.0" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$first_bundle" \
  >"$test_root/concurrent.out" 2>&1; then
  echo "Linux installer accepted a concurrent invocation" >&2
  exit 1
fi
[[ ! -s "$systemctl_log" && ! -s "$sudo_log" ]] || {
  echo "Concurrent Linux install mutated service state" >&2
  exit 1
}
rm -f "$test_home/.cache/cablelabel/install.lock"

fresh_failure_home="$test_root/fresh-failure-home"
fresh_failure_marker="$test_root/fresh-restart-failed"
fresh_failure_bundle="$test_root/bundle-0.3.0"
mkdir -p "$fresh_failure_home"
mkdir -p "$fresh_failure_home/.cache/cablelabel"
printf '99999999\n' >"$fresh_failure_home/.cache/cablelabel/install.lock"
make_bundle "$fresh_failure_bundle" 0.3.0
if HOME="$fresh_failure_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  TEST_HEALTH_VERSION="0.3.0" \
  TEST_FAIL_RESTART_ONCE="$fresh_failure_marker" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$fresh_failure_bundle" \
  >"$test_root/failed-fresh-install.out" 2>&1; then
  echo "Installer accepted a failed fresh service restart" >&2
  exit 1
fi
for leftover in \
  "$fresh_failure_home/.local/opt/cablelabel/current" \
  "$fresh_failure_home/.local/opt/cablelabel/0.3.0" \
  "$fresh_failure_home/.local/bin/cablelabel" \
  "$fresh_failure_home/.config/systemd/user/cablelabel.service" \
  "$fresh_failure_home/.config/cablelabel/environment"; do
  if [[ -e "$leftover" || -L "$leftover" ]]; then
    echo "Fresh-install rollback left behind $leftover" >&2
    exit 1
  fi
done
[[ ! -e "$fresh_failure_home/.cache/cablelabel/install.lock" ]] || {
  echo "Fresh-install rollback left behind the reclaimed install lock" >&2
  exit 1
}
[[ ! -e "$system_udev_rule" ]] || {
  echo "Fresh-install rollback left behind the system udev rule" >&2
  exit 1
}

run_installer "$first_bundle"
assert_service_sequence "first install"
[[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
  "$test_home/.local/opt/cablelabel/0.2.0" ]]
[[ "$(readlink "$test_home/.local/bin/cablelabel")" == \
  "$test_home/.local/opt/cablelabel/current/cablelabel" ]] || {
  echo "Installer did not expose the cablelabel CLI in ~/.local/bin" >&2
  exit 1
}

run_installer "$upgrade_bundle"
assert_service_sequence "upgrade"
[[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
  "$test_home/.local/opt/cablelabel/0.2.1" ]]
[[ -x "$test_home/.local/bin/cablelabel" ]] || {
  echo "Installed cablelabel CLI is not executable after upgrade" >&2
  exit 1
}

cp "$test_home/.config/systemd/user/cablelabel.service" "$test_root/expected-service"
cp "$test_home/.config/cablelabel/environment" "$test_root/expected-environment"
cp "$test_home/.config/cablelabel/70-cablelabel-pt-d600.rules" \
  "$test_root/expected-rendered-rule"

assert_previous_install_restored() {
  local phase="$1"

  [[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
    "$test_home/.local/opt/cablelabel/0.2.1" ]] || {
    echo "$phase did not restore the previous version" >&2
    exit 1
  }
  [[ "$(readlink "$test_home/.local/bin/cablelabel")" == \
    "$test_home/.local/opt/cablelabel/current/cablelabel" ]] || {
    echo "$phase did not restore the CLI link" >&2
    exit 1
  }
  cmp -s "$test_root/expected-service" \
    "$test_home/.config/systemd/user/cablelabel.service" || {
    echo "$phase did not restore the service" >&2
    exit 1
  }
  cmp -s "$test_root/expected-environment" \
    "$test_home/.config/cablelabel/environment" || {
    echo "$phase did not restore the environment" >&2
    exit 1
  }
  cmp -s "$test_root/expected-rendered-rule" \
    "$test_home/.config/cablelabel/70-cablelabel-pt-d600.rules" || {
    echo "$phase did not restore the rendered udev rule" >&2
    exit 1
  }
  [[ -e "$systemctl_state/enabled" && -e "$systemctl_state/active" ]] || {
    echo "$phase did not restore service enablement and activity" >&2
    exit 1
  }
}

run_failed_upgrade() {
  local name="$1"
  local version="$2"
  local failure_variable="$3"
  local marker="$test_root/$name.failed"
  local bundle="$test_root/bundle-$name"

  make_bundle "$bundle" "$version"
  printf 'original system rule\n' >"$system_udev_rule"
  if env \
    HOME="$test_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    TEST_SERVICE_USER="cablelabel_tester" \
    TEST_SYSTEMCTL_LOG="$systemctl_log" \
    TEST_SYSTEMCTL_STATE="$systemctl_state" \
    TEST_SUDO_LOG="$sudo_log" \
    TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
    TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
    TEST_HEALTH_VERSION="$version" \
    "$failure_variable=$marker" \
    "$project_dir/scripts/install-linux-service.sh" --bundle "$bundle" \
    >"$test_root/$name.out" 2>&1; then
    echo "Installer accepted the injected $name failure" >&2
    exit 1
  fi
  [[ "$(<"$system_udev_rule")" == "original system rule" ]] || {
    echo "$name did not restore the previous system udev rule" >&2
    exit 1
  }
  assert_previous_install_restored "$name"
  [[ ! -e "$test_home/.local/opt/cablelabel/$version" ]] || {
    echo "$name left behind failed version $version" >&2
    exit 1
  }
}

run_failed_upgrade install-after-write 0.2.2 TEST_FAIL_SUDO_INSTALL_AFTER_WRITE_ONCE
run_failed_upgrade udev-reload 0.2.3 TEST_FAIL_UDEV_RELOAD_ONCE
run_failed_upgrade udev-trigger 0.2.4 TEST_FAIL_UDEV_TRIGGER_ONCE
run_failed_upgrade service-enable 0.2.5 TEST_FAIL_ENABLE_ONCE

failed_bundle="$test_root/bundle-0.2.2"
restart_marker="$test_root/restart-failed"
make_bundle "$failed_bundle" 0.2.2
printf 'original system rule\n' >"$system_udev_rule"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  TEST_HEALTH_VERSION="0.2.2" \
  TEST_FAIL_RESTART_ONCE="$restart_marker" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$failed_bundle" \
  >"$test_root/failed-upgrade.out" 2>&1; then
  echo "Installer accepted a failed service restart" >&2
  exit 1
fi
[[ "$(<"$system_udev_rule")" == "original system rule" ]] || {
  echo "Installer did not restore the previous system udev rule" >&2
  exit 1
}
[[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
  "$test_home/.local/opt/cablelabel/0.2.1" ]] || {
  echo "Installer did not restore the previous version after failure" >&2
  exit 1
}

same_version_bundle="$test_root/bundle-same-version"
same_version_marker="$test_root/same-version-restart-failed"
make_bundle "$same_version_bundle" 0.2.1
printf 'new bundle bytes\n' >"$same_version_bundle/new-marker"
printf 'old installed bytes\n' >"$test_home/.local/opt/cablelabel/0.2.1/old-marker"
printf 'original system rule\n' >"$system_udev_rule"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  TEST_HEALTH_VERSION="0.2.1" \
  TEST_FAIL_RESTART_ONCE="$same_version_marker" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$same_version_bundle" \
  >"$test_root/same-version.out" 2>&1; then
  echo "Installer accepted a failed same-version reinstall" >&2
  exit 1
fi
assert_previous_install_restored "same-version reinstall"
[[ -f "$test_home/.local/opt/cablelabel/0.2.1/old-marker" ]] || {
  echo "Same-version rollback lost old bundle bytes" >&2
  exit 1
}
[[ ! -e "$test_home/.local/opt/cablelabel/0.2.1/new-marker" ]] || {
  echo "Same-version rollback retained new bundle bytes" >&2
  exit 1
}

disabled_bundle="$test_root/bundle-disabled-state"
disabled_marker="$test_root/disabled-state-restart-failed"
make_bundle "$disabled_bundle" 0.2.6
rm -f "$systemctl_state/enabled" "$systemctl_state/active"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  TEST_HEALTH_VERSION="0.2.6" \
  TEST_FAIL_RESTART_ONCE="$disabled_marker" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$disabled_bundle" \
  >"$test_root/disabled-state.out" 2>&1; then
  echo "Installer accepted the disabled-state failure" >&2
  exit 1
fi
[[ ! -e "$systemctl_state/enabled" && ! -e "$systemctl_state/active" ]] || {
  echo "Rollback did not restore the disabled and inactive service state" >&2
  exit 1
}

: >"$systemctl_state/enabled"
: >"$systemctl_state/active"
rollback_failure_bundle="$test_root/bundle-rollback-failure"
rollback_restart_marker="$test_root/rollback-restart-failed"
rollback_install_marker="$test_root/rollback-install-failed"
make_bundle "$rollback_failure_bundle" 0.2.7
printf 'original system rule\n' >"$system_udev_rule"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  TEST_HEALTH_VERSION="0.2.7" \
  TEST_FAIL_RESTART_ONCE="$rollback_restart_marker" \
  TEST_FAIL_ROLLBACK_INSTALL_ONCE="$rollback_install_marker" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$rollback_failure_bundle" \
  >"$test_root/rollback-failure.out" 2>&1; then
  echo "Installer accepted an incomplete rollback" >&2
  exit 1
fi
[[ "$(<"$test_root/rollback-failure.out")" == *"rollback was incomplete"* ]] || {
  echo "Installer did not report the incomplete rollback" >&2
  exit 1
}
recovery_path="$(awk '/recovery files were preserved/{getline; sub(/^  /, ""); print; exit}' \
  "$test_root/rollback-failure.out")"
[[ -n "$recovery_path" && -d "$recovery_path" ]] || {
  echo "Installer did not preserve rollback recovery files" >&2
  exit 1
}
if command -v trash >/dev/null; then
  trash "$recovery_path"
else
  rm -rf "$recovery_path"
fi

rendered_rule="$(<"$installed_udev_rule")"
[[ "$rendered_rule" == *'OWNER="cablelabel_tester"'* ]]
[[ "$rendered_rule" == *'MODE="0600"'* ]]
[[ "$rendered_rule" == *'TAG+="uaccess"'* ]]
if [[ "$rendered_rule" == *'@CABLELABEL_USER@'* ]]; then
  echo "Rendered udev rule still contains its username placeholder" >&2
  exit 1
fi

sudo_calls_before="$(wc -l <"$sudo_log" | tr -d '[:space:]')"
systemctl_calls_before="$(wc -l <"$systemctl_log" | tr -d '[:space:]')"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER='bad"user' \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SYSTEMCTL_STATE="$systemctl_state" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_SYSTEM_UDEV_RULE="$system_udev_rule" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$upgrade_bundle" \
  >"$test_root/invalid-user.out" 2>&1; then
  echo "Installer accepted an unsafe service username" >&2
  exit 1
fi
sudo_calls_after="$(wc -l <"$sudo_log" | tr -d '[:space:]')"
systemctl_calls_after="$(wc -l <"$systemctl_log" | tr -d '[:space:]')"
[[ "$sudo_calls_after" == "$sudo_calls_before" ]] || {
  echo "Installer invoked sudo for an unsafe service username" >&2
  exit 1
}
[[ "$systemctl_calls_after" == "$systemctl_calls_before" ]] || {
  echo "Installer changed service state after a preflight failure" >&2
  exit 1
}

echo "Linux installer mock tests passed"
