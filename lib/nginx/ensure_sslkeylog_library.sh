# shellcheck shell=bash

function ensure_sslkeylog_library() {
  local image="${1:-$NGINX_IMAGE}"
  local build_script=""
  local image_id="" build_meta="" expected_meta=""

  if [ ! -f "$SSLKEYLOG_LIB_SOURCE_FILE" ]; then
    echo "[Error] Missing TLS keylog helper source: ${SSLKEYLOG_LIB_SOURCE_FILE}" >&2
    return 1
  fi

  image_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
  if [ -n "$image_id" ]; then
    expected_meta="${image}|${image_id}"
  fi

  if [ -s "$SSLKEYLOG_LIB_BUILD_FILE" ] && [ "$SSLKEYLOG_LIB_BUILD_FILE" -nt "$SSLKEYLOG_LIB_SOURCE_FILE" ] && [ -n "$expected_meta" ]; then
    build_meta="$(sed -n '1p' "$SSLKEYLOG_LIB_BUILD_META_FILE" 2>/dev/null || true)"
    if [ "$build_meta" = "$expected_meta" ]; then
      return 0
    fi
  fi

  if [ -z "$image_id" ]; then
    echo "[Warn] Unable to inspect Nginx image identity for ${image}; rebuilding TLS keylog helper." >&2
  fi

  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$SSLKEYLOG_LIB_BUILD_DIR" "$SSLKEYLOG_LIB_BUILD_FILE" "$SSLKEYLOG_LIB_BUILD_META_FILE" || return 1
  fi
  mkdir -p "$SSLKEYLOG_LIB_BUILD_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$SSLKEYLOG_LIB_BUILD_DIR" "$SSLKEYLOG_LIB_BUILD_FILE" "$SSLKEYLOG_LIB_BUILD_META_FILE" || return 1
  fi

  build_script='set -eu
if ! command -v cc >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gcc libc6-dev >/dev/null
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache build-base >/dev/null
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf install -y gcc glibc-devel >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y gcc glibc-devel >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y gcc glibc-devel >/dev/null
  else
    echo "[Error] No compiler or supported package manager found in nginx image." >&2
    exit 1
  fi
fi
out="/out/sslkeylogfile.so"
tmp="${out}.tmp.$$"
rm -f "$tmp"
cc -shared -fPIC -O2 -Wall -Wextra -o "$tmp" /src/sslkeylogfile.c -ldl -pthread
test -s "$tmp"
chmod 755 "$tmp"
mv "$tmp" "$out"'

  echo "[Info] Building TLS keylog helper using Nginx image: ${image}"
  if ! docker run --rm \
    --entrypoint sh \
    -u 0:0 \
    -v "${SSLKEYLOG_LIB_SOURCE_DIR}:/src:ro" \
    -v "${SSLKEYLOG_LIB_BUILD_DIR}:/out" \
    "$image" -c "$build_script"; then
    echo "[Error] Failed to build TLS keylog helper with Nginx image '${image}'." >&2
    return 1
  fi

  if [ ! -s "$SSLKEYLOG_LIB_BUILD_FILE" ]; then
    echo "[Error] TLS keylog helper build did not produce ${SSLKEYLOG_LIB_BUILD_FILE}." >&2
    return 1
  fi

  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$SSLKEYLOG_LIB_BUILD_FILE" "$SSLKEYLOG_LIB_BUILD_META_FILE" || return 1
  fi
  chmod 755 "$SSLKEYLOG_LIB_BUILD_FILE" 2>/dev/null || true
  if [ -n "$expected_meta" ]; then
    printf '%s\n' "$expected_meta" >"$SSLKEYLOG_LIB_BUILD_META_FILE"
  else
    rm -f "$SSLKEYLOG_LIB_BUILD_META_FILE"
  fi
}
