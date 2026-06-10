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
source "$ROOT_DIR/lib/access_log.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_runtime_prep_lock.XXXXXX")"
HOLDER_PID=""

function cleanup() {
  if [ -n "${HOLDER_PID:-}" ]; then
    if kill -0 "$HOLDER_PID" 2>/dev/null; then
      kill "$HOLDER_PID" 2>/dev/null || true
    fi
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}

trap cleanup EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function configure_paths() {
  STATE_DIR="$TMP_ROOT/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  CERTS_DIR="$STATE_DIR/certs"
  NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
  NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
  NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
  BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
  CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
  BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
  BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
  PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
  PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
  NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
  BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
  BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
  BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
  BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
  BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
  BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
  BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
  SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
  SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
  ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
}

function reset_runtime_state() {
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR"
}

function write_legacy_settings() {
  local acl_policy="${1:-deny}"
  cat >"$GLOBAL_SETTINGS_FILE" <<EOF_CONFIG
setting_key,setting_value
ENABLE_AUTO_BACKUPS,true
BACKUP_RETENTION,0
ENABLE_BACKUP_COMPRESSION,true
HTTP_VERSION,http2
CLIENT_IP_HEADER,X-Forwarded-For
PROXY_IP_HEADER,X-Real-IP
TLS_PROTOCOLS,TLSv1.2 TLSv1.3
TLS_CIPHERS,HIGH:!aNULL:!MD5
SECURITY_RULE_STATUS,403
ACL_STATUS,403
ACL_POLICY,${acl_policy}
TRUSTED_PROXY_RANGES,
REAL_IP_RECURSIVE,on
NGINX_IMAGE,nginx
CERTBOT_IMAGE,certbot/certbot
EOF_CONFIG
}

function assert_acl_policy() {
  local expected="${1:-}"
  grep -qx "ACL_POLICY,${expected}" "$GLOBAL_SETTINGS_FILE" ||
    fail_test "Expected ACL_POLICY=${expected}"
}

function assert_no_runtime_prep_backups() {
  [ ! -e "$LAST_POST_BACKUP_FILE" ] ||
    fail_test "bootstrap_config_runtime should not update the post-backup marker"
  [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)" ] ||
    fail_test "bootstrap_config_runtime should not create backup archives"
}

configure_paths
reset_runtime_state
write_legacy_settings "deny"

cat >"$TMP_ROOT/worker_common.sh" <<'EOF_COMMON'
ROOT_DIR="${1:-}"
TMP_ROOT="${2:-}"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/access_log.sh"

STATE_DIR="$TMP_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
CAPTURE_DIR="$STATE_DIR/pcaps"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
PORT_TLS_PROTOCOLS_FILE="$CONFIG_DIR/port_tls_protocols.csv"
PORT_TLS_CIPHERS_FILE="$CONFIG_DIR/port_tls_ciphers.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
EOF_COMMON

cat >"$TMP_ROOT/hold_transaction.sh" <<'EOF_HOLD'
#!/usr/bin/env bash
set -Eeuo pipefail

COMMON_FILE="${1:-}"
ROOT_DIR="${2:-}"
TMP_ROOT="${3:-}"
# shellcheck disable=SC1090
source "$COMMON_FILE" "$ROOT_DIR" "$TMP_ROOT"

begin_transaction_return "runtime_prep_lock_test" "$CONFIG_DIR" || exit 1

tmp_file=""
make_temp_for_file tmp_file "$GLOBAL_SETTINGS_FILE" || {
  transaction_return_failure
  exit 1
}
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
  ACL_POLICY,*) printf '%s\n' "ACL_POLICY,allow" ;;
  *) printf '%s\n' "$line" ;;
  esac
done <"$GLOBAL_SETTINGS_FILE" >"$tmp_file"
finalize_temp_file "$GLOBAL_SETTINGS_FILE" "$tmp_file" || {
  rm -f "$tmp_file"
  transaction_return_failure
  exit 1
}

touch "$TMP_ROOT/transaction-held"
while [ ! -f "$TMP_ROOT/release-transaction" ]; do
  sleep 0.05
done

end_transaction_success
EOF_HOLD
chmod +x "$TMP_ROOT/hold_transaction.sh"

"$TMP_ROOT/hold_transaction.sh" "$TMP_ROOT/worker_common.sh" "$ROOT_DIR" "$TMP_ROOT" &
HOLDER_PID=$!

for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$TMP_ROOT/transaction-held" ] && break
  sleep 0.1
done
[ -f "$TMP_ROOT/transaction-held" ] || fail_test "transaction holder did not start"
assert_acl_policy "allow"

set +e
(
  # shellcheck disable=SC1090
  source "$TMP_ROOT/worker_common.sh" "$ROOT_DIR" "$TMP_ROOT"
  bootstrap_config_runtime
) >"$TMP_ROOT/bootstrap_locked.out" 2>"$TMP_ROOT/bootstrap_locked.err"
locked_status=$?
set -e

[ "$locked_status" -ne 0 ] ||
  fail_test "bootstrap_config_runtime should fail while another process holds the transaction lock"
grep -Fq "Another mutating operation is in progress" "$TMP_ROOT/bootstrap_locked.err" ||
  fail_test "bootstrap_config_runtime did not report the live transaction lock"
assert_acl_policy "allow"
! grep -qx 'NGINX_PULL_MODE,if-missing' "$GLOBAL_SETTINGS_FILE" ||
  fail_test "locked runtime prep should not migrate settings"

touch "$TMP_ROOT/release-transaction"
wait "$HOLDER_PID"
HOLDER_PID=""

rm -f "$BACKUP_DIR"/*.tar.gz "$LAST_POST_BACKUP_FILE" \
  "$BACKUP_DIR/last_rollback_targets.sha256" \
  "$BACKUP_DIR/last_rollback_state.sha256"

bootstrap_config_runtime || fail_test "bootstrap_config_runtime should repair state after the lock is released"
assert_acl_policy "allow"
grep -qx 'NGINX_IMAGE,nginx:latest' "$GLOBAL_SETTINGS_FILE" ||
  fail_test "bootstrap_config_runtime did not normalize NGINX_IMAGE"
grep -qx 'CERTBOT_IMAGE,certbot/certbot:latest' "$GLOBAL_SETTINGS_FILE" ||
  fail_test "bootstrap_config_runtime did not normalize CERTBOT_IMAGE"
grep -qx 'NGINX_PULL_MODE,if-missing' "$GLOBAL_SETTINGS_FILE" ||
  fail_test "bootstrap_config_runtime did not restore NGINX_PULL_MODE"
grep -qx 'CERTBOT_PULL_MODE,if-missing' "$GLOBAL_SETTINGS_FILE" ||
  fail_test "bootstrap_config_runtime did not restore CERTBOT_PULL_MODE"
assert_no_runtime_prep_backups

saved_release_transaction_lock="$(declare -f release_transaction_lock)" ||
  fail_test "release_transaction_lock must be defined for the failure-path check"
release_transaction_lock() {
  return 1
}
CONFIG_RUNTIME_PREP_LOCK_HELD="true"
CONFIG_RUNTIME_PREP_LOCK_OWNER_PID="$$"
TRANSACTION_LOCK_HELD="true"
set +e
_config_end_runtime_prep_lock_if_started true >/dev/null 2>"$TMP_ROOT/runtime_prep_release.err"
release_status=$?
set -e
[ "$release_status" -ne 0 ] ||
  fail_test "_config_end_runtime_prep_lock_if_started should fail when release_transaction_lock fails"
[ "${CONFIG_RUNTIME_PREP_LOCK_HELD:-}" = "true" ] ||
  fail_test "runtime-prep lock marker should remain set when release_transaction_lock fails"
[ "${CONFIG_RUNTIME_PREP_LOCK_OWNER_PID:-}" = "$$" ] ||
  fail_test "runtime-prep lock owner should remain set when release_transaction_lock fails"
[ "${TRANSACTION_LOCK_HELD:-false}" = "true" ] ||
  fail_test "transaction lock marker should remain set when release_transaction_lock fails"
eval "$saved_release_transaction_lock"
unset CONFIG_RUNTIME_PREP_LOCK_HELD CONFIG_RUNTIME_PREP_LOCK_OWNER_PID TRANSACTION_LOCK_HELD

reset_runtime_state
printf '%s\n' "bad_header" >"$GLOBAL_SETTINGS_FILE"
set +e
bootstrap_config_runtime >/dev/null 2>"$TMP_ROOT/bootstrap_invalid.err"
invalid_status=$?
set -e
[ "$invalid_status" -ne 0 ] ||
  fail_test "bootstrap_config_runtime should fail on invalid global settings"
[ ! -d "$TMP_DIR/.dockistrate_transaction.lock" ] ||
  fail_test "bootstrap_config_runtime should release the runtime-prep lock after failure"

echo "runtime prep lock serialization checks passed."
