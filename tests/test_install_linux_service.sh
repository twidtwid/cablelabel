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
sudo_log="$test_root/sudo.log"
installed_udev_rule="$test_root/installed.rules"
mkdir -p "$fake_bin" "$test_home"

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
  exit 0
fi
if [[ "$*" == "--user restart cablelabel.service" && -n "${TEST_FAIL_RESTART_ONCE:-}" && ! -e "$TEST_FAIL_RESTART_ONCE" ]]; then
  : >"$TEST_FAIL_RESTART_ONCE"
  exit 1
fi
printf '%s\n' "$*" >>"$TEST_SYSTEMCTL_LOG"
EOF

cat >"$fake_bin/udevadm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$fake_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_SUDO_LOG"
if [[ "$1" == "install" ]]; then
  cp "$3" "$TEST_INSTALLED_UDEV_RULE"
fi
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
    TEST_SUDO_LOG="$sudo_log" \
    TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
    TEST_HEALTH_VERSION="$version" \
    "$project_dir/scripts/install-linux-service.sh" --bundle "$bundle"
}

first_bundle="$test_root/bundle-0.2.0"
upgrade_bundle="$test_root/bundle-0.2.1"
make_bundle "$first_bundle" 0.2.0
make_bundle "$upgrade_bundle" 0.2.1

fresh_failure_home="$test_root/fresh-failure-home"
fresh_failure_marker="$test_root/fresh-restart-failed"
fresh_failure_bundle="$test_root/bundle-0.3.0"
mkdir -p "$fresh_failure_home"
make_bundle "$fresh_failure_bundle" 0.3.0
if HOME="$fresh_failure_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
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

failed_bundle="$test_root/bundle-0.2.2"
restart_marker="$test_root/restart-failed"
make_bundle "$failed_bundle" 0.2.2
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER="cablelabel_tester" \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  TEST_HEALTH_VERSION="0.2.2" \
  TEST_FAIL_RESTART_ONCE="$restart_marker" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$failed_bundle" \
  >"$test_root/failed-upgrade.out" 2>&1; then
  echo "Installer accepted a failed service restart" >&2
  exit 1
fi
[[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
  "$test_home/.local/opt/cablelabel/0.2.1" ]] || {
  echo "Installer did not restore the previous version after failure" >&2
  exit 1
}

rendered_rule="$(<"$installed_udev_rule")"
[[ "$rendered_rule" == *'OWNER="cablelabel_tester"'* ]]
[[ "$rendered_rule" == *'MODE="0600"'* ]]
[[ "$rendered_rule" == *'TAG+="uaccess"'* ]]
if [[ "$rendered_rule" == *'@CABLELABEL_USER@'* ]]; then
  echo "Rendered udev rule still contains its username placeholder" >&2
  exit 1
fi

sudo_calls_before="$(wc -l <"$sudo_log" | tr -d '[:space:]')"
if HOME="$test_home" \
  PATH="$fake_bin:/usr/bin:/bin" \
  TEST_SERVICE_USER='bad"user' \
  TEST_SYSTEMCTL_LOG="$systemctl_log" \
  TEST_SUDO_LOG="$sudo_log" \
  TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
  "$project_dir/scripts/install-linux-service.sh" --bundle "$upgrade_bundle" \
  >"$test_root/invalid-user.out" 2>&1; then
  echo "Installer accepted an unsafe service username" >&2
  exit 1
fi
sudo_calls_after="$(wc -l <"$sudo_log" | tr -d '[:space:]')"
[[ "$sudo_calls_after" == "$sudo_calls_before" ]] || {
  echo "Installer invoked sudo for an unsafe service username" >&2
  exit 1
}

echo "Linux installer mock tests passed"
