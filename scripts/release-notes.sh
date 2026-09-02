#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
changelog="${2:-CHANGELOG.md}"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "Usage: $(basename "$0") VERSION [CHANGELOG]" >&2
  exit 2
}
[[ -s "$changelog" ]] || {
  echo "Changelog not found or empty: $changelog" >&2
  exit 1
}

notes="$(awk -v version="$version" '
  /^## / {
    if (found) exit
    if ($2 == version) {
      found = 1
      next
    }
  }
  found && !started && /^[[:space:]]*$/ { next }
  found {
    started = 1
    print
  }
  END { if (!found) exit 3 }
' "$changelog")" || {
  echo "No changelog section found for version $version" >&2
  exit 1
}

[[ -n "${notes//[[:space:]]/}" ]] || {
  echo "Changelog section for version $version is empty" >&2
  exit 1
}
printf '%s\n' "$notes"
