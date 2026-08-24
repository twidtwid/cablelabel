#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unit_file="${1:-$project_dir/linux/cablelabel.service}"
expected_exec_start='ExecStart=%h/.local/opt/cablelabel/current/cablelabel'

[[ "$(uname -s)" == "Linux" ]] || {
  echo "Linux systemd service verification must run on Linux." >&2
  exit 1
}
command -v systemd-analyze >/dev/null || {
  echo "systemd-analyze is required to verify the Linux service." >&2
  exit 1
}
[[ -f "$unit_file" ]] || {
  echo "Linux systemd service not found: $unit_file" >&2
  exit 1
}

exec_start=""
exec_start_count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ExecStart=*)
      exec_start="$line"
      exec_start_count=$((exec_start_count + 1))
      ;;
  esac
done <"$unit_file"

if [[ "$exec_start_count" -ne 1 || "$exec_start" != "$expected_exec_start" ]]; then
  echo "Linux service must contain exactly: $expected_exec_start" >&2
  exit 1
fi

verification_exec="$(type -P true)"
[[ -x "$verification_exec" ]] || {
  echo "Cannot locate an executable for systemd service verification." >&2
  exit 1
}

test_root="$(mktemp -d)"
cleanup() {
  if command -v trash >/dev/null; then
    trash "$test_root"
  else
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

verification_unit="$test_root/cablelabel.service"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" == "$expected_exec_start" ]]; then
    printf 'ExecStart=%s\n' "$verification_exec"
  else
    printf '%s\n' "$line"
  fi
done <"$unit_file" >"$verification_unit"

systemd-analyze --user --recursive-errors=yes verify "$verification_unit"
echo "Verified Linux systemd service: $unit_file"
