# shellcheck shell=bash

function _config_checksum() {
  local dir="${1:-}"
  [ -d "$dir" ] || {
    echo ""
    return 0
  }

  local checksum=""
  if command -v sha256sum >/dev/null 2>&1; then
    checksum=$(find "$dir" -type f -exec sha256sum {} \; | sort | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    checksum=$(find "$dir" -type f -exec shasum -a 256 {} \; | sort | shasum -a 256 | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    checksum=$(find "$dir" -type f -exec openssl dgst -sha256 {} \; |
      awk 'match($0, /^SHA256\((.+)\)= ([0-9a-fA-F]+)/, m) { printf "%s  %s\n", m[2], m[1] }' |
      sort |
      openssl dgst -sha256 |
      awk '{print $NF}')
  else
    echo "[Error] Unable to find a SHA-256 checksum tool (sha256sum, shasum, or openssl)." >&2
    return 1
  fi

  printf '%s' "$checksum"
}
