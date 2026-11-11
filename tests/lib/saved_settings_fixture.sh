# shellcheck shell=bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAVED_SETTINGS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-settings-permissions.XXXXXX")"
SAVED_SETTINGS_TEST_DIR="$(cd "$SAVED_SETTINGS_TEST_DIR" && pwd -P)"
SAVED_SETTINGS_ORIGINAL_UMASK="$(umask)"
trap 'umask "$SAVED_SETTINGS_ORIGINAL_UMASK"; rm -rf "$SAVED_SETTINGS_TEST_DIR"' EXIT

for settings_module in config utils backups access_log permissions global_settings; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$settings_module.sh"
done

SAVED_SETTINGS_FILTER="${1:-}"
SAVED_SETTINGS_CASE_COUNT=0
SAVED_SETTINGS_MARKER='DUMMY_SETTINGS_TOKEN_quoted,value'

function saved_settings_fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function saved_settings_mode() {
  local mode=""
  # This subprocess only observes metadata. A failed platform probe must not
  # invoke inherited Bash 3 transaction callbacks; errors still reach callers.
  mode="$(
    trap - ERR EXIT
    command stat -c '%a' "$1" 2>/dev/null || command stat -f '%Lp' "$1"
  )" || return 1
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  [ "${#mode}" -le 4 ] || return 1
  printf '%s\n' "$mode"
}

function saved_settings_owner() {
  local owner=""
  owner="$(
    trap - ERR EXIT
    command stat -c '%u:%g' "$1" 2>/dev/null || command stat -f '%u:%g' "$1"
  )" || return 1
  case "$owner" in
  *[!0-9:]* | :* | *: | *:*:*) return 1 ;;
  *:*) ;;
  *) return 1 ;;
  esac
  printf '%s\n' "$owner"
}

function saved_settings_assert_mode() {
  local actual=""
  actual="$(trap - ERR EXIT; saved_settings_mode "$1")" ||
    saved_settings_fail "Unable to inspect settings mode: $1"
  [ "$actual" = "$2" ] || saved_settings_fail "$1: expected mode $2, found $actual"
}

# Production modules consume these dynamically scoped runtime paths and options.
# shellcheck disable=SC2034
function saved_settings_reset() {
  BASE_DIR="$SAVED_SETTINGS_TEST_DIR/$1"
  STATE_DIR="$BASE_DIR/state"
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
  STATE_SCHEMA_VERSION_FILE="$CONFIG_DIR/state_schema_version"
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
  INHERITANCE_FILE="$CONFIG_DIR/dedicated_host_inheritance.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
  FULL_BACKUP_FILE="$BACKUP_DIR/last_full_backup.txt"
  FULL_BACKUP_CHECKSUM_FILE="$BACKUP_DIR/last_full_backup.sha256"
  CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
  INTERACTIVE_RECENT_FILE="$CONFIG_DIR/interactive_recent.csv"
  INTERACTIVE_FAVORITES_FILE="$CONFIG_DIR/interactive_favorites.csv"
  LOG_FILE="$LOG_DIR/docker_manager.log"
  AUDIT_LOG_FILE="$LOG_DIR/audit.log"
  SKIP_DOCKER_CHECKS=true
  ENABLE_LOGGING=false
  config_reset_defaults
  NGINX_DOCKER_OPTS="--env 'SETTINGS_TEST_TOKEN=$SAVED_SETTINGS_MARKER'"
  SAVED_FAIL_CHMOD=""
  SAVED_NOOP_CHMOD=""
  SAVED_CHMOD_REQUIRED_MODE=""
  SAVED_FAIL_STAT=""
  SAVED_BAD_STAT=""
  SAVED_FAIL_CHOWN=""
  SAVED_FAIL_MV=""
  SAVED_NOOP_MV=""
  SAVED_PARTIAL_MV=""
  SAVED_CHMOD_HIT="$BASE_DIR/chmod.hit"
  SAVED_CHOWN_HIT="$BASE_DIR/chown.hit"
  SAVED_STAT_HIT="$BASE_DIR/stat.hit"
  SAVED_MV_HIT="$BASE_DIR/mv.hit"
  mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TMP_DIR"
}

function saved_settings_seed() {
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  command chmod "${1:-600}" "$GLOBAL_SETTINGS_FILE"
}

function saved_settings_assert_no_temps() {
  local leftover=""
  leftover="$(find "$CONFIG_DIR" -maxdepth 1 -name '.global_settings*' -print)"
  [ -z "$leftover" ] || saved_settings_fail 'Settings operation left a temporary file'
}

function saved_settings_assert_original() {
  cmp -s "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/original.csv" ||
    saved_settings_fail 'Failed operation changed original settings bytes'
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$SAVED_ORIGINAL_MODE"
  [ "$(saved_settings_owner "$GLOBAL_SETTINGS_FILE")" = "$SAVED_ORIGINAL_OWNER" ] ||
    saved_settings_fail 'Failed operation changed original settings ownership'
  saved_settings_assert_no_temps
}

function saved_settings_snapshot() {
  cp "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/original.csv"
  SAVED_ORIGINAL_MODE="$(trap - ERR EXIT; saved_settings_mode "$GLOBAL_SETTINGS_FILE")" || return 1
  SAVED_ORIGINAL_OWNER="$(trap - ERR EXIT; saved_settings_owner "$GLOBAL_SETTINGS_FILE")" || return 1
}

function saved_settings_matches() {
  [ -n "$2" ] || return 1
  if [ "$2" = __settings_temp__ ]; then
    case "$1" in
    "$CONFIG_DIR"/*) [ "$1" != "$GLOBAL_SETTINGS_FILE" ]; return $? ;;
    esac
    return 1
  fi
  # Failure selectors deliberately accept globs for private staging paths.
  # shellcheck disable=SC2254
  case "$1" in $2) return 0 ;; esac
  return 1
}

function chmod() {
  local arg=""
  if [ -n "${SAVED_CHMOD_REQUIRED_MODE:-}" ]; then
    case "${1:-}" in
    "$SAVED_CHMOD_REQUIRED_MODE" | "0$SAVED_CHMOD_REQUIRED_MODE" | "00$SAVED_CHMOD_REQUIRED_MODE") ;;
    *) command chmod "$@"; return $? ;;
    esac
  fi
  for arg in "$@"; do
    if saved_settings_matches "$arg" "${SAVED_FAIL_CHMOD:-}"; then
      : >"$SAVED_CHMOD_HIT"
      return 1
    fi
    if saved_settings_matches "$arg" "${SAVED_NOOP_CHMOD:-}"; then
      : >"$SAVED_CHMOD_HIT"
      return 0
    fi
  done
  command chmod "$@"
}

function stat() {
  local arg="" real_stat=""
  for arg in "$@"; do
    if saved_settings_matches "$arg" "${SAVED_FAIL_STAT:-}"; then
      : >"$SAVED_STAT_HIT"
      return 1
    fi
    if saved_settings_matches "$arg" "${SAVED_BAD_STAT:-}"; then
      : >"$SAVED_STAT_HIT"
      printf '%s\n' malformed
      return 0
    fi
  done
  # Bash 3 can invoke inherited ERR callbacks for `command stat` even when a
  # caller handles a failed GNU probe. Preserve the external tool's semantics.
  real_stat="$(type -P stat)" || return 1
  "$real_stat" "$@" || return 1
}

function chown() {
  local arg=""
  for arg in "$@"; do
    if saved_settings_matches "$arg" "${SAVED_FAIL_CHOWN:-}"; then
      : >"$SAVED_CHOWN_HIT"
      return 1
    fi
  done
  command chown "$@"
}

function mv() {
  local arg="" target=""
  for arg in "$@"; do target="$arg"; done
  if saved_settings_matches "$target" "${SAVED_FAIL_MV:-}"; then
    : >"$SAVED_MV_HIT"
    return 1
  fi
  if saved_settings_matches "$target" "${SAVED_NOOP_MV:-}"; then
    : >"$SAVED_MV_HIT"
    return 0
  fi
  if saved_settings_matches "$target" "${SAVED_PARTIAL_MV:-}" && [ ! -e "$SAVED_MV_HIT" ]; then
    : >"$SAVED_MV_HIT"
    command mv "$@" || return 1
    return 1
  fi
  command mv "$@"
}

function _nginx_image_runs_as_root() { return 0; }
function capture_docker_logs() { :; }
function log_msg() { :; }
function update_nginx_config() { :; }
function confirm_prompt() { return 0; }
function docker() { saved_settings_fail 'Settings library fixture unexpectedly invoked Docker'; }

function saved_settings_run_case() {
  local name="$1" status=0
  shift
  if [ -n "$SAVED_SETTINGS_FILTER" ] && [ "$SAVED_SETTINGS_FILTER" != "$name" ]; then
    return 0
  fi
  # A conditional around the child would disable errexit throughout its real
  # transaction functions. Capture the child status without that suppression.
  set +e
  (
    set -Eeuo pipefail
    "$@"
  ) >"$SAVED_SETTINGS_TEST_DIR/case-output" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    cat "$SAVED_SETTINGS_TEST_DIR/case-output" >&2
    saved_settings_fail "$name failed with status $status"
  fi
  SAVED_SETTINGS_CASE_COUNT=$((SAVED_SETTINGS_CASE_COUNT + 1))
  printf '[tests] %s: PASS\n' "$name"
}

function saved_settings_finish() {
  [ "$SAVED_SETTINGS_CASE_COUNT" -gt 0 ] || saved_settings_fail 'No matching settings test case'
  printf '[tests] %s: PASS (%s cases)\n' "$1" "$SAVED_SETTINGS_CASE_COUNT"
}
