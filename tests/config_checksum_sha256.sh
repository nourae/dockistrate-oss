#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/backups/_config_checksum.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_checksum.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

echo "hello" >"${tmp_dir}/file.txt"
echo "spaced" >"${tmp_dir}/file with spaces.txt"

checksum="$(_config_checksum "$tmp_dir")"
if [[ ! "$checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "[Error] Expected SHA-256 checksum, got: ${checksum}" >&2
  exit 1
fi

openssl_only_path="${tmp_dir}/openssl-only-path"
mkdir -p "$openssl_only_path"
for tool in find sort awk openssl; do
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  if [ -z "$tool_path" ]; then
    echo "[Error] Required checksum fallback tool is unavailable: ${tool}" >&2
    exit 1
  fi
  ln -s "$tool_path" "${openssl_only_path}/${tool}"
done

openssl_checksum="$(PATH="$openssl_only_path" _config_checksum "$tmp_dir")"
if [ "$openssl_checksum" != "$checksum" ]; then
  echo "[Error] OpenSSL-only checksum differs from the preferred-tool checksum." >&2
  echo "[Error] Preferred: ${checksum}" >&2
  echo "[Error] OpenSSL:   ${openssl_checksum}" >&2
  exit 1
fi

echo "changed" >"${tmp_dir}/file.txt"
changed_openssl_checksum="$(PATH="$openssl_only_path" _config_checksum "$tmp_dir")"
if [[ ! "$changed_openssl_checksum" =~ ^[0-9a-fA-F]{64}$ ]]; then
  echo "[Error] Expected changed OpenSSL SHA-256 checksum, got: ${changed_openssl_checksum}" >&2
  exit 1
fi
if [ "$changed_openssl_checksum" = "$openssl_checksum" ]; then
  echo "[Error] OpenSSL-only checksum did not change after file content changed." >&2
  exit 1
fi
changed_checksum="$(_config_checksum "$tmp_dir")"
if [ "$changed_openssl_checksum" != "$changed_checksum" ]; then
  echo "[Error] Changed OpenSSL-only checksum differs from the preferred-tool checksum." >&2
  exit 1
fi

echo "Config checksum SHA-256 check passed."
