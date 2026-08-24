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
exit 0
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

  : >"$systemctl_log"
  HOME="$test_home" \
    PATH="$fake_bin:/usr/bin:/bin" \
    TEST_SERVICE_USER="cablelabel_tester" \
    TEST_SYSTEMCTL_LOG="$systemctl_log" \
    TEST_SUDO_LOG="$sudo_log" \
    TEST_INSTALLED_UDEV_RULE="$installed_udev_rule" \
    "$project_dir/scripts/install-linux-service.sh" --bundle "$bundle"
}

first_bundle="$test_root/bundle-0.2.0"
upgrade_bundle="$test_root/bundle-0.2.1"
make_bundle "$first_bundle" 0.2.0
make_bundle "$upgrade_bundle" 0.2.1

run_installer "$first_bundle"
assert_service_sequence "first install"
[[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
  "$test_home/.local/opt/cablelabel/0.2.0" ]]

run_installer "$upgrade_bundle"
assert_service_sequence "upgrade"
[[ "$(readlink "$test_home/.local/opt/cablelabel/current")" == \
  "$test_home/.local/opt/cablelabel/0.2.1" ]]

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
