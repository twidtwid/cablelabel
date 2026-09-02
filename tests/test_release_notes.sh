#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp)"
cleanup() {
  if command -v trash >/dev/null; then
    trash "$fixture"
  else
    rm -f "$fixture"
  fi
}
trap cleanup EXIT

cat >"$fixture" <<'EOF'
# Changelog

## 1.2.0 - 2026-09-02

- Current release item.
- Another current item.

## 1.1.0 - 2026-08-01

- Older item.
EOF

notes="$("$project_dir/scripts/release-notes.sh" 1.2.0 "$fixture")"
[[ "$notes" == $'- Current release item.\n- Another current item.' ]] || {
  echo "Unexpected release notes:" >&2
  printf '%s\n' "$notes" >&2
  exit 1
}

if "$project_dir/scripts/release-notes.sh" 9.9.9 "$fixture" >/dev/null 2>&1; then
  echo "Expected missing release version to fail" >&2
  exit 1
fi
