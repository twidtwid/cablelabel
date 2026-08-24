# shellcheck shell=bash disable=SC2034

PTOUCH_VERSION="0.5.0"
PTOUCH_LICENSE_URL="https://raw.githubusercontent.com/vowstar/ptouch-rs/v${PTOUCH_VERSION}/LICENSE"
PTOUCH_LICENSE_SHA="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"

sha256_file() {
  if command -v sha256sum >/dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

download_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"
  local artifact_name="$4"

  if [[ -f "$destination" ]] && [[ "$(sha256_file "$destination")" == "$expected_sha" ]]; then
    return
  fi

  curl -fL --connect-timeout 10 --max-time 120 --retry 3 --retry-delay 2 \
    --retry-all-errors "$url" -o "$destination.download"
  local downloaded_sha
  downloaded_sha="$(sha256_file "$destination.download")"
  if [[ "$downloaded_sha" != "$expected_sha" ]]; then
    echo "$artifact_name checksum mismatch" >&2
    return 1
  fi
  mv "$destination.download" "$destination"
}

validate_app_version() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]
}

validate_service_username() {
  local value="$1"

  [[ ${#value} -le 256 && "$value" =~ ^[A-Za-z_][A-Za-z0-9_.-]*[$]?$ ]]
}

validate_port() {
  local value="$1"
  local port_number

  [[ "$value" =~ ^[0-9]+$ && ${#value} -le 5 ]] || return 1
  port_number=$(( 10#$value ))
  (( port_number >= 1 && port_number <= 65535 ))
}

validate_trusted_origin() {
  local origin="$1"
  local authority host origin_port label remaining

  [[ "$origin" == https://* ]] || return 1
  authority="${origin#https://}"
  authority="${authority%/}"
  [[ -n "$authority" ]] || return 1
  [[ "$authority" != */* && "$authority" != *\?* && "$authority" != *\#* ]] || return 1
  [[ "$authority" != *@* && "$authority" != *[[:space:]]* ]] || return 1

  if [[ "$authority" == *:* ]]; then
    host="${authority%:*}"
    origin_port="${authority##*:}"
    validate_port "$origin_port" || return 1
  else
    host="$authority"
  fi

  [[ -n "$host" && "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1
  remaining="$host"
  while [[ "$remaining" == *.* ]]; do
    label="${remaining%%.*}"
    remaining="${remaining#*.}"
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  [[ "$remaining" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-20}"
  local attempt

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    if curl --fail --silent --connect-timeout 1 --max-time 2 "$url" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_http_body() {
  local url="$1"
  local expected_body="$2"
  local attempts="${3:-20}"
  local attempt body

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    if body="$(curl --fail --silent --connect-timeout 1 --max-time 2 "$url")" &&
      [[ "$body" == "$expected_body" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}
