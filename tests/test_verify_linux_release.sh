#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cleanup() {
  if command -v trash >/dev/null; then
    trash "$test_root"
  else
    rm -rf "$test_root"
  fi
}
trap cleanup EXIT

cat >"$fake_bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then
  echo x86_64
else
  /usr/bin/uname "$@"
fi
EOF

cat >"$fake_bin/file" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  */cablelabel|*/ptouch) echo "$1: ELF 64-bit LSB executable, x86-64" ;;
  *) echo "$1: PNG image data" ;;
esac
EOF

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
output=""
url="${*: -1}"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then
    output="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$output" ]]; then
  printf 'png\n' >"$output"
elif [[ "$url" == */api/health ]]; then
  printf '{"name": "cablelabel", "version": "0.3.0"}'
fi
EOF
chmod +x "$fake_bin"/*
export PATH="$fake_bin:/usr/bin:/bin"

make_archive() {
  local name="$1"
  local omitted_file="${2:-}"
  local mutation="${3:-}"
  local root="$test_root/$name"

  mkdir -p \
    "$root/dist/cablelabel/_internal/bin" \
    "$root/dist/cablelabel/_internal/fonts" \
    "$root/dist/cablelabel/_internal/licenses" \
    "$root/dist/cablelabel/_internal/web" \
    "$root/scripts/lib" "$root/linux"
  cp "$project_dir/scripts/install-linux-service.sh" "$root/scripts/"
  cp "$project_dir/scripts/lib/common.sh" "$root/scripts/lib/"
  cp "$project_dir/linux/cablelabel.service" "$root/linux/"
  cp "$project_dir/linux/70-cablelabel-pt-d600.rules" "$root/linux/"
  cat >"$root/dist/cablelabel/cablelabel" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  echo "cablelabel 0.3.0"
  exit 0
fi
if [[ "$*" == *" preview "* ]]; then
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output" ]]; then
      printf 'png\n' >"$2"
      exit 0
    fi
    shift
  done
fi
if [[ "$*" == *" serve "* ]]; then
  echo '{"ok": true, "url": "http://127.0.0.1:43123"}'
  while :; do sleep 1; done
fi
exit 2
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$root/dist/cablelabel/_internal/bin/ptouch"
  printf 'notice\n' >"$root/dist/cablelabel/_internal/THIRD_PARTY_NOTICES.md"
  printf 'font\n' >"$root/dist/cablelabel/_internal/fonts/RobotoCondensed-Bold.ttf"
  printf 'license\n' >"$root/dist/cablelabel/_internal/licenses/ptouch-rs-GPL-3.0.txt"
  printf 'license\n' >"$root/dist/cablelabel/_internal/licenses/Roboto-Apache-2.0.txt"
  printf '<!doctype html>\n' >"$root/dist/cablelabel/_internal/web/index.html"
  chmod +x "$root/dist/cablelabel/cablelabel" \
    "$root/dist/cablelabel/_internal/bin/ptouch" \
    "$root/scripts/install-linux-service.sh"
  printf '0.3.0\n' >"$root/dist/cablelabel/_internal/VERSION"
  if [[ -n "$omitted_file" ]]; then
    unlink "$root/$omitted_file"
  fi
  case "$mutation" in
    unexpected-exec-start)
      sed -i.bak 's#ExecStart=.*#ExecStart=/tmp/not-cablelabel#' \
        "$root/linux/cablelabel.service"
      unlink "$root/linux/cablelabel.service.bak"
      ;;
    missing-udev-placeholder)
      sed -i.bak 's/@CABLELABEL_USER@/root/' \
        "$root/linux/70-cablelabel-pt-d600.rules"
      unlink "$root/linux/70-cablelabel-pt-d600.rules.bak"
      ;;
    noop-executable)
      printf '#!/usr/bin/env bash\nexit 0\n' >"$root/dist/cablelabel/cablelabel"
      chmod +x "$root/dist/cablelabel/cablelabel"
      ;;
  esac
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

make_archive missing-runtime-asset dist/cablelabel/_internal/web/index.html
if "$project_dir/scripts/verify-linux-release.sh" \
  "$test_root/missing-runtime-asset.tar.gz" >"$test_root/missing-runtime-asset.out" 2>&1; then
  echo "Release verifier accepted a bundle missing a runtime asset" >&2
  exit 1
fi

for mutation in unexpected-exec-start missing-udev-placeholder; do
  make_archive "$mutation" "" "$mutation"
  if "$project_dir/scripts/verify-linux-release.sh" "$test_root/$mutation.tar.gz" \
    >"$test_root/$mutation.out" 2>&1; then
    echo "Release verifier accepted $mutation" >&2
    exit 1
  fi
done

make_archive noop-executable "" noop-executable
if "$project_dir/scripts/verify-linux-release.sh" \
  "$test_root/noop-executable.tar.gz" >"$test_root/noop-executable.out" 2>&1; then
  echo "Release verifier accepted a nonfunctional application executable" >&2
  exit 1
fi

echo "Linux release archive verification tests passed"
