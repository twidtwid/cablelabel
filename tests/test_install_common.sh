#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${BASH_VERSION:-}" ]]; then
  script_path="${BASH_SOURCE[0]}"
else
  script_path="$0"
fi
project_dir="$(cd "$(dirname "$script_path")/.." && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$project_dir/scripts/lib/common.sh"

validate_app_version 0.2.0
if validate_app_version version-two; then
  echo "Expected invalid app version" >&2
  exit 1
fi

for value in 1 9462 65535 00080; do
  validate_port "$value" || {
    echo "Expected valid port: $value" >&2
    exit 1
  }
done

for value in "" 0 65536 nope 123456; do
  if validate_port "$value"; then
    echo "Expected invalid port: $value" >&2
    exit 1
  fi
done

for value in https://label.example.com https://label.example.com/ https://label.example.com:9462; do
  validate_trusted_origin "$value" || {
    echo "Expected valid origin: $value" >&2
    exit 1
  }
done

for value in \
  "http://label.example.com" \
  "https://" \
  "https://label.example.com/path" \
  "https://user@label.example.com" \
  "https://label.example.com?query" \
  "https://-label.example.com" \
  "https://label..example.com"; do
  if validate_trusted_origin "$value"; then
    echo "Expected invalid origin: $value" >&2
    exit 1
  fi
done
