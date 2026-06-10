#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_revoke_fail.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

CERTS_DIR="$TMP_ROOT/certs"
mtls_dir="$CERTS_DIR/mtls/example.com"
mkdir -p "$mtls_dir"

printf 'old-crl\n' >"${mtls_dir}/ca.crl"
printf 'client-cert\n' >"${mtls_dir}/client1.crt"
printf 'client-key\n' >"${mtls_dir}/client1.key"

function openssl() {
  if [ "${1:-}" = "ca" ]; then
    return 1
  fi
  command openssl "$@"
}

set +e
output="$(_revoke_backend_client_cert "$mtls_dir" client1 true 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] _revoke_backend_client_cert succeeded unexpectedly." >&2
  exit 1
fi

if [ ! -f "${mtls_dir}/client1.crt" ] || [ ! -f "${mtls_dir}/client1.key" ]; then
  echo "[Error] Client certificate files were removed after revoke failure." >&2
  exit 1
fi

if [ "$(cat "${mtls_dir}/ca.crl")" != "old-crl" ]; then
  echo "[Error] Existing CRL was modified after revoke failure." >&2
  exit 1
fi

if ! grep -Fq "Failed to revoke client certificate" <<<"$output"; then
  echo "[Error] Expected revoke failure message missing." >&2
  echo "$output" >&2
  exit 1
fi

echo "mTLS revoke failure preserves client files."
