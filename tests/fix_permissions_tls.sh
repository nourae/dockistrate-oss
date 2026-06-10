#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

STATE_DIR="${ROOT_DIR}/state"
CERTS_DIR="${STATE_DIR}/certs"
CERTS_ROOT="${CERTS_DIR}/testcase/live/demo"
KEY_FILE="${CERTS_ROOT}/privkey.pem"
SECONDARY_KEY="${CERTS_ROOT}/client.key"
P12_FILE="${CERTS_ROOT}/client.p12"
PFX_FILE="${CERTS_ROOT}/CLIENT.PFX"

FIX_PERMS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix_permissions_tls.d"
if [ -d "$FIX_PERMS_DIR" ]; then
  for helper_file in "$FIX_PERMS_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$helper_file"
  done
fi

trap cleanup EXIT

mkdir -p "$CERTS_ROOT"
printf 'dummy-key' >"$KEY_FILE"
printf 'client-key' >"$SECONDARY_KEY"
printf 'pkcs12-bytes' >"$P12_FILE"
printf 'pkcs12-bytes-alt' >"$PFX_FILE"
chmod 600 "$KEY_FILE"
chmod 640 "$SECONDARY_KEY"
chmod 600 "$P12_FILE"
chmod 640 "$PFX_FILE"

./dockistrate.sh fix-permissions >/dev/null

mode_key="$(get_mode "$KEY_FILE")"
mode_secondary="$(get_mode "$SECONDARY_KEY")"
mode_p12="$(get_mode "$P12_FILE")"
mode_pfx="$(get_mode "$PFX_FILE")"

case "$mode_key" in
600) ;;
*)
  echo "Expected privkey.pem to be tightened to 0600 but mode is ${mode_key}" >&2
  exit 1
  ;;
esac

case "$mode_secondary" in
600) ;;
*)
  echo "Expected client.key to be tightened to 0600 but mode is ${mode_secondary}" >&2
  exit 1
  ;;
esac

case "$mode_p12" in
600) ;;
*)
  echo "Expected client.p12 to be tightened to 0600 but mode is ${mode_p12}" >&2
  exit 1
  ;;
esac

case "$mode_pfx" in
600) ;;
*)
  echo "Expected CLIENT.PFX to be tightened to 0600 but mode is ${mode_pfx}" >&2
  exit 1
  ;;
esac

echo "TLS and PKCS#12 permission regression checks passed."
