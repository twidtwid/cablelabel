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
analyze_log="$test_root/systemd-analyze.log"
mkdir -p "$fake_bin"

cat >"$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Linux
EOF

cat >"$fake_bin/systemd-analyze" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 4 ]]
[[ "$1" == "--user" ]]
[[ "$2" == "--recursive-errors=yes" ]]
[[ "$3" == "verify" ]]
unit_file="$4"
[[ -f "$unit_file" ]]

exec_start=""
while IFS= read -r line; do
  case "$line" in
    ExecStart=*) exec_start="${line#ExecStart=}" ;;
  esac
done <"$unit_file"

[[ -n "$exec_start" ]]
[[ "$exec_start" != *'%h/'* ]]
[[ -x "$exec_start" ]]
printf '%s\n' "$unit_file" >>"$TEST_ANALYZE_LOG"
EOF

chmod +x "$fake_bin/uname" "$fake_bin/systemd-analyze"

PATH="$fake_bin:/usr/bin:/bin" \
  TEST_ANALYZE_LOG="$analyze_log" \
  "$project_dir/scripts/verify-linux-service.sh"

[[ "$(wc -l <"$analyze_log" | tr -d '[:space:]')" == "1" ]]

private_tmp_unit="$test_root/private-tmp.service"
awk '
  /^UMask=/ { print "PrivateTmp=true" }
  { print }
' "$project_dir/linux/cablelabel.service" >"$private_tmp_unit"

if PATH="$fake_bin:/usr/bin:/bin" \
  TEST_ANALYZE_LOG="$analyze_log" \
  "$project_dir/scripts/verify-linux-service.sh" "$private_tmp_unit" \
  >"$test_root/private-tmp.out" 2>&1; then
  echo "Verifier accepted a service that isolates the shared printer lock" >&2
  exit 1
fi
[[ "$(wc -l <"$analyze_log" | tr -d '[:space:]')" == "1" ]]

wrong_unit="$test_root/wrong.service"
sed 's|^ExecStart=.*|ExecStart=%h/.local/bin/cablelabel|' \
  "$project_dir/linux/cablelabel.service" >"$wrong_unit"

if PATH="$fake_bin:/usr/bin:/bin" \
  TEST_ANALYZE_LOG="$analyze_log" \
  "$project_dir/scripts/verify-linux-service.sh" "$wrong_unit" \
  >"$test_root/wrong.out" 2>&1; then
  echo "Verifier accepted the wrong production ExecStart path" >&2
  exit 1
fi
[[ "$(wc -l <"$analyze_log" | tr -d '[:space:]')" == "1" ]]

echo "Linux systemd service verification tests passed"
