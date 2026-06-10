#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/utils.sh"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

CERTS_DIR="${tmp_root}/certs"
mkdir -p "${CERTS_DIR}/mtls/example.com"

out=""
if ! normalize_mtls_dir out "${CERTS_DIR}/mtls/example.com"; then
  echo "[Error] Expected normalize_mtls_dir to accept valid mTLS path." >&2
  exit 1
fi

root_real="$(_realpath_portable "${CERTS_DIR}/mtls")"
if [[ "$out" != "${root_real}/"* ]]; then
  echo "[Error] Normalized mTLS path not under expected root: ${out}" >&2
  exit 1
fi

bad_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_bad.XXXXXX")"
if normalize_mtls_dir out "$bad_dir" 2>/dev/null; then
  echo "[Error] normalize_mtls_dir accepted path outside mTLS root: ${bad_dir}" >&2
  exit 1
fi

rm -rf "${CERTS_DIR}/mtls"
ln -s "$bad_dir" "${CERTS_DIR}/mtls"
if normalize_mtls_dir out "${CERTS_DIR}/mtls/example.com" 2>/dev/null; then
  echo "[Error] normalize_mtls_dir accepted a symlinked mTLS root." >&2
  exit 1
fi
if ensure_mtls_root_dir 2>/dev/null; then
  echo "[Error] ensure_mtls_root_dir accepted a symlinked mTLS root." >&2
  exit 1
fi

echo "mTLS directory validation checks passed."
