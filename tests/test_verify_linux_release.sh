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

make_archive() {
  local name="$1"
  local omitted_file="${2:-}"
  local root="$test_root/$name"

  mkdir -p "$root/dist/cablelabel/_internal" "$root/scripts/lib" "$root/linux"
  cp "$project_dir/scripts/install-linux-service.sh" "$root/scripts/"
  cp "$project_dir/scripts/lib/common.sh" "$root/scripts/lib/"
  cp "$project_dir/linux/cablelabel.service" "$root/linux/"
  cp "$project_dir/linux/70-cablelabel-pt-d600.rules" "$root/linux/"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$root/dist/cablelabel/cablelabel"
  chmod +x "$root/dist/cablelabel/cablelabel" "$root/scripts/install-linux-service.sh"
  printf '0.3.0\n' >"$root/dist/cablelabel/_internal/VERSION"
  if [[ -n "$omitted_file" ]]; then
    unlink "$root/$omitted_file"
  fi
  tar -C "$test_root" -czf "$test_root/$name.tar.gz" "$name"
}

make_archive complete
"$project_dir/scripts/verify-linux-release.sh" "$test_root/complete.tar.gz" >/dev/null

for required in linux/cablelabel.service linux/70-cablelabel-pt-d600.rules; do
  fixture="missing-$(basename "$required")"
  make_archive "$fixture" "$required"
  if "$project_dir/scripts/verify-linux-release.sh" "$test_root/$fixture.tar.gz" \
    >"$test_root/$fixture.out" 2>&1; then
    echo "Release verifier accepted archive missing $required" >&2
    exit 1
  fi
done

echo "Linux release archive verification tests passed"
