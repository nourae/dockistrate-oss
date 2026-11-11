#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_owner.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"

mkdir -p "$CONFIG_DIR" "$CERTS_DIR/mtls/owner.test"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,owner.test,10.0.0.5:8000,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
cat >"$BACKEND_ALIASES_FILE" <<'EOF_ALIASES'
record_type,hostname,target_domain
dedicated,admin.owner.test,owner.test
EOF_ALIASES

OWNER_MTLS_DIR="$CERTS_DIR/mtls/owner.test"
printf 'ca\n' >"$OWNER_MTLS_DIR/ca.crt"
printf 'crl\n' >"$OWNER_MTLS_DIR/ca.crl"
cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
domain,mtls_directory
owner.test,$OWNER_MTLS_DIR
EOF_MTLS

resolved_dir=""
resolved_owner=""
_mtls_resolve_effective_mapping resolved_dir resolved_owner admin.owner.test
if [ "$resolved_dir" != "$OWNER_MTLS_DIR" ] || [ "$resolved_owner" != "owner.test" ]; then
  echo "[Error] Dedicated-host mTLS inheritance did not preserve the target row owner." >&2
  exit 1
fi

if [ "$(get_backend_mtls_dir admin.owner.test)" != "$OWNER_MTLS_DIR" ]; then
  echo "[Error] Dedicated-host mTLS lookup did not return the target-owned directory." >&2
  exit 1
fi

mutation_dir=""
_resolve_backend_mtls_dir mutation_dir admin.owner.test
if [ "$mutation_dir" != "$OWNER_MTLS_DIR" ]; then
  echo "[Error] Dedicated-host mTLS mutation resolver rejected valid target ownership." >&2
  exit 1
fi

directives="$(_backend_mtls_directives admin.owner.test)"
if ! grep -Fq 'ssl_client_certificate /etc/letsencrypt/mtls/owner.test/ca.crt;' <<<"$directives"; then
  echo "[Error] Dedicated-host rendering did not use the validated target-owned CA path." >&2
  echo "$directives" >&2
  exit 1
fi

printf 'owner.test,%s\n' "$OWNER_MTLS_DIR" >"$BACKEND_MTLS_FILE"
set +e
invalid_header_output="$(list_backend_cas 2>&1)"
invalid_header_status=$?
set -e
if [ "$invalid_header_status" -eq 0 ]; then
  echo "[Error] list_backend_cas accepted mTLS state with a missing header." >&2
  exit 1
fi
if ! grep -Fq '[Error] Invalid header in ' <<<"$invalid_header_output"; then
  echo "[Error] list_backend_cas did not report the invalid mTLS state header." >&2
  echo "$invalid_header_output" >&2
  exit 1
fi
if grep -Fq '[Info] No backend CAs configured' <<<"$invalid_header_output"; then
  echo "[Error] list_backend_cas reported invalid mTLS state as an empty configuration." >&2
  exit 1
fi

cat >"$BACKEND_MTLS_FILE" <<EOF_NONCANONICAL
domain,mtls_directory
Owner.Test,$OWNER_MTLS_DIR
EOF_NONCANONICAL
if validate_backend_mtls_state_for_render >/dev/null 2>&1; then
  echo "[Error] Render validation accepted a noncanonical mTLS owner key." >&2
  exit 1
fi
if get_backend_mtls_dir owner.test >/dev/null 2>&1; then
  echo "[Error] mTLS lookup accepted noncanonical persisted owner state." >&2
  exit 1
fi

cat >"$BACKEND_MTLS_FILE" <<EOF_MALFORMED
domain,mtls_directory
owner.test,$OWNER_MTLS_DIR,unexpected
EOF_MALFORMED
if validate_backend_mtls_state_for_render >/dev/null 2>&1; then
  echo "[Error] Render validation accepted a malformed mTLS row." >&2
  exit 1
fi

rm -rf "$OWNER_MTLS_DIR"
printf 'not-a-directory\n' >"$OWNER_MTLS_DIR"
cat >"$BACKEND_MTLS_FILE" <<EOF_FILE_PATH
domain,mtls_directory
owner.test,$OWNER_MTLS_DIR
EOF_FILE_PATH
if validate_backend_mtls_state_for_render >/dev/null 2>&1; then
  echo "[Error] Render validation accepted a regular file as an mTLS backend directory." >&2
  exit 1
fi

printf '%s\n' 'domain,mtls_directory' >"$BACKEND_MTLS_FILE"
printf 'bad\033[31m.test,%s\n' "$OWNER_MTLS_DIR" >>"$BACKEND_MTLS_FILE"
set +e
invalid_render_output="$(validate_backend_mtls_state_for_render 2>&1)"
invalid_render_status=$?
invalid_list_output="$(list_backend_cas 2>&1)"
invalid_list_status=$?
set -e
if [ "$invalid_render_status" -eq 0 ] || [[ "$invalid_render_output" == *$'\033'* ]]; then
  echo "[Error] Render validation accepted or exposed a control-character owner key." >&2
  exit 1
fi
if [ "$invalid_list_status" -eq 0 ]; then
  echo "[Error] list_backend_cas accepted a control-character owner key." >&2
  exit 1
fi
if [[ "$invalid_list_output" == *$'\033'* ]] || ! grep -Fq '[invalid domain 2]' <<<"$invalid_list_output"; then
  echo "[Error] list_backend_cas exposed an invalid owner key instead of a safe placeholder." >&2
  exit 1
fi

printf '%s\n' 'domain,mtls_directory' >"$BACKEND_MTLS_FILE"
printf 'owner.test,%s\033[31m\n' "$OWNER_MTLS_DIR" >>"$BACKEND_MTLS_FILE"
set +e
invalid_path_output="$(validate_backend_mtls_state_for_render 2>&1)"
invalid_path_status=$?
set -e
if [ "$invalid_path_status" -eq 0 ] || [[ "$invalid_path_output" == *$'\033'* ]]; then
  echo "[Error] Render validation accepted or exposed a control-character mTLS path." >&2
  exit 1
fi

printf 'mTLS owner binding preserves inheritance and safely rejects malformed, noncanonical, non-directory, or control-character state.\n'
