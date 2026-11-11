#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_crl_fail.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

CERTS_DIR="$TMP_ROOT/certs"
mtls_dir="$CERTS_DIR/mtls/example.com"
mkdir -p "$mtls_dir"

# Reach CRL generation with genuine validated authority/history, then inject
# the failure so this remains a publication/rollback test.
_generate_backend_ca "$mtls_dir" example.com >/dev/null 2>&1
_init_backend_mtls_state "$mtls_dir" fresh
_generate_backend_crl "$mtls_dir" >/dev/null 2>&1
cp "$mtls_dir/ca.crl" "$TMP_ROOT/original.crl"

function openssl() {
  if [ "${1:-}" = "ca" ]; then
    return 1
  fi
  command openssl "$@"
}

set +e
output="$(_generate_backend_crl "$mtls_dir" 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] _generate_backend_crl succeeded unexpectedly." >&2
  exit 1
fi

if ! cmp -s "$mtls_dir/ca.crl" "$TMP_ROOT/original.crl"; then
  echo "[Error] Existing CRL was modified after generation failure." >&2
  exit 1
fi

if find "$mtls_dir" -maxdepth 1 -name '.ca.crl.tmp.*' | grep -q .; then
  echo "[Error] Temporary CRL file was left behind after failure." >&2
  exit 1
fi

if ! grep -Fq "Failed to generate CRL" <<<"$output"; then
  echo "[Error] Expected CRL failure message missing." >&2
  echo "$output" >&2
  exit 1
fi

echo "mTLS CRL failure preserves existing CRL."
