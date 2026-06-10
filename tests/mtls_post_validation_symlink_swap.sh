#!/usr/bin/env bash
# shellcheck disable=SC2218
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

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mtls_swap.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function configure_paths() {
  BASE_DIR="$TMP_ROOT/repo"
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
}

function reset_runtime_tree() {
  rm -rf "$TMP_ROOT/repo" "$TMP_ROOT/outside-ca" "$TMP_ROOT/outside-state" "$TMP_ROOT/openssl-called"
  configure_paths
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls"
  cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,10.0.0.2:8080,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
}

function log_msg() { :; }
function capture_docker_logs() { :; }
function update_nginx_config() { :; }

function openssl() {
  local keyout="" out=""
  : >"$TMP_ROOT/openssl-called"
  while [ "$#" -gt 0 ]; do
    case "${1:-}" in
    -keyout)
      keyout="${2:-}"
      shift 2
      ;;
    -out)
      out="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
    esac
  done
  [ -n "$keyout" ] && printf 'key\n' >"$keyout"
  [ -n "$out" ] && printf 'cert\n' >"$out"
  return 0
}

reset_runtime_tree
outside_ca="$TMP_ROOT/outside-ca"
expected_mtls_dir="${CERTS_DIR%/}/mtls/example.com"
mkdir -p "$outside_ca/example.com"
swap_marker="$TMP_ROOT/swap-ca"

function mkdir() {
  if [ "$#" -eq 2 ] && [ "${1:-}" = "-p" ] && [ "${2:-}" = "$expected_mtls_dir" ] && [ ! -e "$swap_marker" ]; then
    command mkdir "$@"
    rm -rf "${CERTS_DIR%/}/mtls"
    ln -s "$outside_ca" "${CERTS_DIR%/}/mtls"
    : >"$swap_marker"
    return 0
  fi
  command mkdir "$@"
}

set +e
(enable_backend_mtls example.com) >"$TMP_ROOT/enable.out" 2>&1
enable_status=$?
set -e

[ -e "$swap_marker" ] || fail_test "enable_backend_mtls test did not exercise the mTLS root swap"
[ "$enable_status" -ne 0 ] || fail_test "enable_backend_mtls succeeded after mTLS root swap"
[ ! -e "$outside_ca/example.com/ca.key" ] || fail_test "enable_backend_mtls wrote outside ca.key after mTLS root swap"
[ ! -e "$outside_ca/example.com/ca.crt" ] || fail_test "enable_backend_mtls wrote outside ca.crt after mTLS root swap"
[ ! -e "$TMP_ROOT/openssl-called" ] || fail_test "enable_backend_mtls reached openssl after mTLS root swap: $(cat "$TMP_ROOT/enable.out")"

unset -f mkdir

reset_runtime_tree
sibling_mtls_dir="${CERTS_DIR%/}/mtls/other.com"
symlink_mtls_dir="${CERTS_DIR%/}/mtls/example.com"
mkdir -p "$sibling_mtls_dir"
printf 'keep\n' >"$sibling_mtls_dir/sentinel.txt"
ln -s other.com "$symlink_mtls_dir"

set +e
(enable_backend_mtls example.com) >"$TMP_ROOT/enable-sibling.out" 2>&1
enable_sibling_status=$?
set -e

[ "$enable_sibling_status" -ne 0 ] || fail_test "enable_backend_mtls accepted a symlinked backend mTLS directory"
[ -f "$sibling_mtls_dir/sentinel.txt" ] || fail_test "enable_backend_mtls removed sibling mTLS sentinel"
[ ! -e "$sibling_mtls_dir/ca.key" ] || fail_test "enable_backend_mtls wrote sibling ca.key through backend mTLS symlink"
[ ! -e "$sibling_mtls_dir/ca.crt" ] || fail_test "enable_backend_mtls wrote sibling ca.crt through backend mTLS symlink"
[ ! -e "$TMP_ROOT/openssl-called" ] || fail_test "enable_backend_mtls reached openssl through backend mTLS symlink: $(cat "$TMP_ROOT/enable-sibling.out")"
[ -L "$symlink_mtls_dir" ] || fail_test "enable_backend_mtls removed symlinked backend mTLS directory"

reset_runtime_tree
outside_state="$TMP_ROOT/outside-state"
expected_mtls_dir="${CERTS_DIR%/}/mtls/example.com"
mkdir -p "$outside_state/example.com"
swap_marker="$TMP_ROOT/swap-state"

function mkdir() {
  if [ "$#" -eq 2 ] && [ "${1:-}" = "-p" ] && [ "${2:-}" = "$expected_mtls_dir" ] && [ ! -e "$swap_marker" ]; then
    command mkdir "$@"
    rm -rf "${CERTS_DIR%/}/mtls"
    ln -s "$outside_state" "${CERTS_DIR%/}/mtls"
    : >"$swap_marker"
    return 0
  fi
  command mkdir "$@"
}

set +e
(_init_backend_mtls_state "$expected_mtls_dir") >"$TMP_ROOT/state.out" 2>&1
state_status=$?
set -e

[ -e "$swap_marker" ] || fail_test "_init_backend_mtls_state test did not exercise the mTLS root swap"
[ "$state_status" -ne 0 ] || fail_test "_init_backend_mtls_state succeeded after mTLS root swap"
[ ! -e "$outside_state/example.com/index.txt" ] || fail_test "_init_backend_mtls_state wrote outside index.txt after mTLS root swap"
[ ! -e "$outside_state/example.com/serial" ] || fail_test "_init_backend_mtls_state wrote outside serial after mTLS root swap"
[ ! -e "$outside_state/example.com/openssl.cnf" ] || fail_test "_init_backend_mtls_state wrote outside openssl.cnf after mTLS root swap"

unset -f mkdir

reset_runtime_tree
sibling_mtls_dir="${CERTS_DIR%/}/mtls/other.com"
symlink_mtls_dir="${CERTS_DIR%/}/mtls/example.com"
mkdir -p "$sibling_mtls_dir"
printf 'keep\n' >"$sibling_mtls_dir/sentinel.txt"
ln -s other.com "$symlink_mtls_dir"

set +e
(_init_backend_mtls_state "$symlink_mtls_dir") >"$TMP_ROOT/state-sibling.out" 2>&1
state_sibling_status=$?
set -e

[ "$state_sibling_status" -ne 0 ] || fail_test "_init_backend_mtls_state accepted a symlinked backend mTLS directory"
[ -f "$sibling_mtls_dir/sentinel.txt" ] || fail_test "_init_backend_mtls_state removed sibling mTLS sentinel"
[ ! -e "$sibling_mtls_dir/index.txt" ] || fail_test "_init_backend_mtls_state wrote sibling index.txt through backend mTLS symlink"
[ ! -e "$sibling_mtls_dir/serial" ] || fail_test "_init_backend_mtls_state wrote sibling serial through backend mTLS symlink"
[ ! -e "$sibling_mtls_dir/openssl.cnf" ] || fail_test "_init_backend_mtls_state wrote sibling openssl.cnf through backend mTLS symlink"
[ -L "$symlink_mtls_dir" ] || fail_test "_init_backend_mtls_state removed symlinked backend mTLS directory"

reset_runtime_tree
sibling_mtls_dir="${CERTS_DIR%/}/mtls/other.com"
symlink_mtls_dir="${CERTS_DIR%/}/mtls/example.com"
mkdir -p "$sibling_mtls_dir"
printf 'keep\n' >"$sibling_mtls_dir/sentinel.txt"
ln -s other.com "$symlink_mtls_dir"
printf '%s\n%s\n' \
  "$STATE_BACKEND_MTLS_HEADER" \
  "example.com,$symlink_mtls_dir" >"$BACKEND_MTLS_FILE"

set +e
(_mtls_remove_dir_if_exists "$symlink_mtls_dir") >"$TMP_ROOT/remove-helper-sibling.out" 2>&1
remove_helper_sibling_status=$?
(remove_backend_ca example.com) >"$TMP_ROOT/remove-ca-sibling.out" 2>&1
remove_ca_sibling_status=$?
set -e

[ "$remove_helper_sibling_status" -ne 0 ] || fail_test "_mtls_remove_dir_if_exists accepted a symlinked backend mTLS directory"
[ "$remove_ca_sibling_status" -ne 0 ] || fail_test "remove_backend_ca accepted a symlinked backend mTLS directory"
[ -d "$sibling_mtls_dir" ] || fail_test "mTLS removal deleted sibling backend directory"
[ -f "$sibling_mtls_dir/sentinel.txt" ] || fail_test "mTLS removal removed sibling mTLS sentinel"
[ -L "$symlink_mtls_dir" ] || fail_test "mTLS removal deleted symlinked backend mTLS directory"
if ! grep -q '^example.com,' "$BACKEND_MTLS_FILE"; then
  fail_test "remove_backend_ca changed mTLS state after rejecting a symlinked backend directory"
fi

echo "mTLS post-validation symlink swap checks passed."
