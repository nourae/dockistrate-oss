#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/cli/arg_choices_misc.sh"

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_input_validation.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT
OPENSSL_X509_LOG="$TMP_ROOT/openssl-x509.log"

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CERTS_DIR="$STATE_DIR/certs"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls"
cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { :; }
function _ensure_tls_permissions() { chmod 600 "$1"; }
function _generate_backend_ca() {
  local mtls_dir="${1:-}"
  mkdir -p "$mtls_dir"
  printf 'ca\n' >"${mtls_dir}/ca.crt"
  printf 'key\n' >"${mtls_dir}/ca.key"
}
function _generate_backend_crl() {
  local mtls_dir="${1:-}"
  printf 'crl\n' >"${mtls_dir}/ca.crl"
}
function openssl() {
  local output_file="" input_file=""
  if [ "${1:-}" = "x509" ]; then
    shift
    while [ "$#" -gt 0 ]; do
      if [ "${1:-}" = "-in" ]; then
        input_file="${2:-}"
        break
      fi
      shift
    done
    printf '%s\n' "$input_file" >>"$OPENSSL_X509_LOG"
    return 1
  fi
  if [ "${1:-}" = "pkcs12" ]; then
    while [ "$#" -gt 0 ]; do
      if [ "${1:-}" = "-out" ]; then
        output_file="${2:-}"
        break
      fi
      shift
    done
    [ -n "$output_file" ] || return 1
    printf 'p12\n' >"$output_file"
    return 0
  fi
  command openssl "$@"
}

set +e
invalid_domain_output="$(enable_backend_mtls '../../../outside' 2>&1)"
invalid_domain_status=$?
unknown_domain_output="$(enable_backend_mtls unknown.example 2>&1)"
unknown_domain_status=$?
set -e

if [ "$invalid_domain_status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls accepted an invalid traversal domain." >&2
  exit 1
fi
if ! grep -Fq "Invalid domain" <<<"$invalid_domain_output"; then
  echo "[Error] Invalid traversal domain was not rejected with a validation error." >&2
  echo "$invalid_domain_output" >&2
  exit 1
fi
if [ -e "$TMP_ROOT/outside" ] || [ -L "$TMP_ROOT/outside" ]; then
  echo "[Error] Invalid traversal domain created a path outside CERTS_DIR/mtls." >&2
  exit 1
fi
if [ "$unknown_domain_status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls accepted an unknown backend domain." >&2
  exit 1
fi
if ! grep -Fq "Domain 'unknown.example' not found" <<<"$unknown_domain_output"; then
  echo "[Error] Unknown backend domain was not rejected before mTLS setup." >&2
  echo "$unknown_domain_output" >&2
  exit 1
fi
if [ -e "$CERTS_DIR/mtls/unknown.example" ] || [ -L "$CERTS_DIR/mtls/unknown.example" ]; then
  echo "[Error] Unknown backend domain created mTLS state." >&2
  exit 1
fi

rm -rf "$CERTS_DIR/mtls"
symlinked_mtls_root="$TMP_ROOT/symlinked-mtls-root"
mkdir -p "$symlinked_mtls_root"
ln -s "$symlinked_mtls_root" "$CERTS_DIR/mtls"
set +e
symlink_root_output="$(enable_backend_mtls example.com 2>&1)"
symlink_root_status=$?
set -e
if [ "$symlink_root_status" -eq 0 ]; then
  echo "[Error] enable_backend_mtls accepted a symlinked mTLS root." >&2
  exit 1
fi
case "$symlink_root_output" in
*"symlinked"*"mTLS"* | *"symlinked"*"runtime path"*) ;;
*)
  echo "[Error] Symlinked mTLS root rejection did not report a symlink guard failure." >&2
  echo "$symlink_root_output" >&2
  exit 1
  ;;
esac
if find "$symlinked_mtls_root" -mindepth 1 | grep -q .; then
  echo "[Error] Symlinked mTLS root received generated PKI material." >&2
  find "$symlinked_mtls_root" -mindepth 1 -print >&2
  exit 1
fi
rm -f "$CERTS_DIR/mtls"
mkdir -p "$CERTS_DIR/mtls"

outside_mtls_dir="$TMP_ROOT/outside-mtls"
mkdir -p "$outside_mtls_dir"
printf 'outside-ca\n' >"${outside_mtls_dir}/ca.crt"
printf 'outside-alice\n' >"${outside_mtls_dir}/alice.crt"
printf 'outside-bob\n' >"${outside_mtls_dir}/bob.crt"
printf '%s\n%s\n' \
  "$STATE_BACKEND_MTLS_HEADER" \
  "example.com,$outside_mtls_dir" >"$BACKEND_MTLS_FILE"

tampered_choice_output_file="$TMP_ROOT/tampered-client-choices.txt"
: >"$OPENSSL_X509_LOG"
: >"$tampered_choice_output_file"
set +e
tampered_cas_output="$(list_backend_cas 2>&1)"
tampered_cas_status=$?
CURRENT_ARGS=("example.com")
tampered_choice_status=0
for choice_cmd in remove-backend-client-cert replace-backend-client-cert export-backend-client-p12; do
  choice_output="$(__arg_choices_client_name "$choice_cmd" 2>&1)"
  choice_status=$?
  if [ "$choice_status" -ne 0 ]; then
    tampered_choice_status=$choice_status
  fi
  if [ -n "$choice_output" ]; then
    printf '%s:%s\n' "$choice_cmd" "$choice_output" >>"$tampered_choice_output_file"
  fi
done
tampered_list_output="$(list_backend_client_certs example.com 2>&1)"
tampered_list_status=$?
tampered_replace_output="$(replace_backend_ca example.com 2>&1)"
tampered_replace_status=$?
set -e
tampered_choice_output="$(cat "$tampered_choice_output_file")"

if [ "$tampered_cas_status" -eq 0 ]; then
  echo "[Error] list_backend_cas accepted a tampered persisted mTLS path." >&2
  exit 1
fi
if ! grep -Fq "[invalid mTLS path]" <<<"$tampered_cas_output"; then
  echo "[Error] list_backend_cas did not report invalid persisted mTLS state safely." >&2
  echo "$tampered_cas_output" >&2
  exit 1
fi
if grep -Fq "$outside_mtls_dir" <<<"$tampered_cas_output"; then
  echo "[Error] list_backend_cas leaked the outside mTLS directory path." >&2
  echo "$tampered_cas_output" >&2
  exit 1
fi
if grep -Fq "${outside_mtls_dir}/ca.crt" "$OPENSSL_X509_LOG"; then
  echo "[Error] list_backend_cas invoked openssl against the outside CA path." >&2
  cat "$OPENSSL_X509_LOG" >&2
  exit 1
fi
if [ "$tampered_choice_status" -ne 0 ]; then
  echo "[Error] Client-name choices failed instead of quietly suppressing invalid mTLS state." >&2
  exit 1
fi
if [ -n "$tampered_choice_output" ]; then
  echo "[Error] Client-name choices leaked certificates from outside the mTLS root." >&2
  echo "$tampered_choice_output" >&2
  exit 1
fi
if [ "$tampered_list_status" -eq 0 ]; then
  echo "[Error] list_backend_client_certs accepted a tampered persisted mTLS path." >&2
  exit 1
fi
if ! grep -Fq "must reside within" <<<"$tampered_list_output"; then
  echo "[Error] Tampered persisted mTLS path was not rejected by list containment validation." >&2
  echo "$tampered_list_output" >&2
  exit 1
fi
if [ "$tampered_replace_status" -eq 0 ]; then
  echo "[Error] replace_backend_ca accepted a tampered persisted mTLS path." >&2
  exit 1
fi
if ! grep -Fq "must reside within" <<<"$tampered_replace_output"; then
  echo "[Error] Tampered persisted mTLS path was not rejected by replace containment validation." >&2
  echo "$tampered_replace_output" >&2
  exit 1
fi
if [ -e "$outside_mtls_dir/index.txt" ] || [ -L "$outside_mtls_dir/index.txt" ]; then
  echo "[Error] mTLS commands mutated a path outside CERTS_DIR/mtls." >&2
  exit 1
fi

valid_mtls_dir="$CERTS_DIR/mtls/example.com"
mkdir -p "$valid_mtls_dir"
printf 'domain,mtls_directory\nexample.com,%s\n' "$valid_mtls_dir" >"$BACKEND_MTLS_FILE"
printf 'client-cert\n' >"${valid_mtls_dir}/client1.crt"
printf 'client-key\n' >"${valid_mtls_dir}/client1.key"
printf 'ca-cert\n' >"${valid_mtls_dir}/ca.crt"
chmod 600 "${valid_mtls_dir}/client1.key"

function _write_backend_openssl_conf() {
  return 1
}

set +e
init_failure_output="$(list_backend_client_certs example.com 2>&1)"
init_failure_status=$?
set -e

if [ "$init_failure_status" -eq 0 ]; then
  echo "[Error] list_backend_client_certs ignored mTLS state initialization failure." >&2
  exit 1
fi
if ! grep -Fq "Failed to initialize mTLS state" <<<"$init_failure_output"; then
  echo "[Error] list_backend_client_certs did not report mTLS state initialization failure." >&2
  echo "$init_failure_output" >&2
  exit 1
fi
if grep -Fq "client1" <<<"$init_failure_output"; then
  echo "[Error] list_backend_client_certs printed client entries after initialization failure." >&2
  echo "$init_failure_output" >&2
  exit 1
fi

set +e
invalid_env_output="$(export_backend_client_p12 example.com client1 --password-env 'BAD-NAME' 2>&1)"
invalid_env_status=$?
VALID_P12_PASSWORD='top-secret'
valid_env_output="$(export_backend_client_p12 example.com client1 --password-env VALID_P12_PASSWORD 2>&1)"
valid_env_status=$?
set -e

if [ "$invalid_env_status" -eq 0 ]; then
  echo "[Error] export_backend_client_p12 accepted an invalid env var name." >&2
  exit 1
fi
if ! grep -Fq "Invalid environment variable name" <<<"$invalid_env_output"; then
  echo "[Error] Invalid password env var name was not rejected cleanly." >&2
  echo "$invalid_env_output" >&2
  exit 1
fi
if [ "$valid_env_status" -ne 0 ]; then
  echo "[Error] export_backend_client_p12 rejected a valid env var name." >&2
  echo "$valid_env_output" >&2
  exit 1
fi
if [ "$(cat "${valid_mtls_dir}/client1.p12")" != "p12" ]; then
  echo "[Error] Valid env var export did not produce the expected PKCS#12 bundle." >&2
  exit 1
fi

echo "mTLS input validation rejects traversal domains, tampered paths, and invalid env var names."
