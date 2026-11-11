# shellcheck shell=bash

function _sslkeylog_source_fingerprint() {
  local fingerprint=""
  [ -f "${SSLKEYLOG_LIB_SOURCE_FILE:-}" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    fingerprint="$(sha256sum <"$SSLKEYLOG_LIB_SOURCE_FILE")" || return 1
  elif command -v shasum >/dev/null 2>&1; then
    fingerprint="$(shasum -a 256 <"$SSLKEYLOG_LIB_SOURCE_FILE")" || return 1
  elif command -v openssl >/dev/null 2>&1; then
    fingerprint="$(openssl dgst -sha256 -r <"$SSLKEYLOG_LIB_SOURCE_FILE")" || return 1
  else
    echo "[Error] Unable to find a SHA-256 checksum tool for the TLS keylog helper." >&2
    return 1
  fi
  fingerprint="${fingerprint%%[[:space:]]*}"
  [[ "$fingerprint" =~ ^[0-9a-fA-F]{64}$ ]] || {
    echo "[Error] Invalid SHA-256 fingerprint for the TLS keylog helper source." >&2
    return 1
  }
  printf '%s\n' "$fingerprint" | tr '[:upper:]' '[:lower:]'
}

function ensure_sslkeylog_library() {
  local image="${1:-$NGINX_IMAGE}"
  require_valid_image_ref "$image" "Nginx TLS keylog helper" || return 1
  local build_script=""
  local image_id="" build_meta="" expected_meta="" source_fingerprint="" built_fingerprint=""

  if [ ! -f "$SSLKEYLOG_LIB_SOURCE_FILE" ]; then
    echo "[Error] Missing TLS keylog helper source: ${SSLKEYLOG_LIB_SOURCE_FILE}" >&2
    return 1
  fi
  source_fingerprint="$(_sslkeylog_source_fingerprint)" || {
    echo "[Error] Unable to fingerprint TLS keylog helper source." >&2
    return 1
  }

  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$SSLKEYLOG_LIB_BUILD_DIR" "$SSLKEYLOG_LIB_BUILD_FILE" "$SSLKEYLOG_LIB_BUILD_META_FILE" || return 1
  fi

  image_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
  if [ -n "$image_id" ]; then
    expected_meta="${image}|${image_id}"$'\n'"source=${source_fingerprint}"
  fi

  if [ -s "$SSLKEYLOG_LIB_BUILD_FILE" ] && [ -n "$expected_meta" ]; then
    build_meta="$(cat "$SSLKEYLOG_LIB_BUILD_META_FILE" 2>/dev/null || true)"
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
  # A failed or interrupted rebuild must not leave metadata claiming that the
  # previous source still describes a potentially replaced output file.
  rm -f "$SSLKEYLOG_LIB_BUILD_META_FILE" || return 1
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
  built_fingerprint="$(_sslkeylog_source_fingerprint)" || return 1
  if [ "$built_fingerprint" != "$source_fingerprint" ]; then
    echo "[Error] TLS keylog helper source changed during the build; retry before using it." >&2
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
