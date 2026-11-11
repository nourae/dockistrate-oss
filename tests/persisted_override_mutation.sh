#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/http_version.sh"
source "$ROOT_DIR/lib/headers.sh"
source "$ROOT_DIR/lib/security_rules.sh"
source "$ROOT_DIR/lib/backends/set_dedicated_host_inherit.sh"
# shellcheck source=../lib/cli/command_visibility.sh
source "$ROOT_DIR/lib/cli/command_visibility.sh"
source "$ROOT_DIR/lib/cli/run_command.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_override_mutation.XXXXXX")"
exec 3>&2
function cleanup_test() {
  local status=$?
  if [ "$status" -ne 0 ] && [ -f "$TEST_ROOT/command.log" ]; then cat "$TEST_ROOT/command.log" >&3; fi
  rm -rf "$TEST_ROOT"
  return "$status"
}
trap cleanup_test EXIT
BASE_DIR="$TEST_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
mkdir -p "$CONFIG_DIR"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
INHERITANCE_FILE="$CONFIG_DIR/dedicated_host_inheritance.csv"

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function assert_contents() {
  [ "$(cat "$1")" = "$2" ] || fail_test "Unexpected rows in $1 ($CASE_NAME)"
}
function expect_value() {
  local expected="$1" actual=""
  shift
  actual="$("$@")" || fail_test "Lookup failed after mutation: $*"
  [ "$actual" = "$expected" ] || fail_test "Wrong lookup after mutation: $*"
}

# Exercise the real dispatch/setter/getter/CSV paths. Only unrelated runtime,
# backup and transaction work is stubbed; rendering retains the real preflight.
function domain_exists() { [ "$1" = mixed.example.com ]; }
function dedicated_host_exists() { [ "$1" = mixed.example.com ]; }
function backend_for_dedicated_host() { :; }
function _config_begin_transaction_if_needed() { printf -v "$1" '%s' false; }
function _config_end_transaction_if_started() { :; }
function transaction_is_active() { return 0; }
function transaction_return_failure() { return 1; }
function create_backup() { :; }
function log_msg() { :; }
function audit_log() { :; }
function _sr_validate_backend_acl_status_transition() { :; }
function update_nginx_config() { validate_settings_for_render; }
function update_nginx_config_for_security_change() { validate_settings_for_render; }

files=("$BACKEND_HTTP_FILE" "$BACKEND_CLIENT_IP_HEADER_FILE" "$BACKEND_PROXY_IP_HEADER_FILE"
  "$BACKEND_ACL_POLICY_FILE" "$BACKEND_ACL_STATUS_FILE" "$BACKEND_SECURITY_RULE_STATUS_FILE")
headers=("$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER"
  "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$STATE_BACKEND_ACL_POLICIES_HEADER"
  "$STATE_BACKEND_ACL_STATUSES_HEADER" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER")
names=(http client_header proxy_header acl_policy acl_status security_status)
commands=(backend-http-version backend-client-ip-header backend-proxy-ip-header
  backend-acl-policy backend-acl-status backend-security-rule-status)
getters=(get_backend_http_version get_backend_client_ip_header get_backend_proxy_ip_header
  get_backend_acl_policy get_backend_acl_status get_backend_security_rule_status)
old_values=(http1.1 X-Old-Client X-Old-Proxy deny 403 403)
new_values=(http1.0 off X-Case-Preserved-Proxy allow 451 429)
read_values=(http1.0 '' X-Case-Preserved-Proxy allow 451 429)
for ((kind = 0; kind < 6; kind++)); do printf '%s\n' "${headers[$kind]}" >"${files[$kind]}"; done
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" >"$INHERITANCE_FILE"

# Optional selectors let old-code negative controls independently demonstrate
# each schema and each action failing, rather than stopping at the first case.
selected_case="${1:-all}"
selected_action="${2:-all}"
VERBOSE=false
for INTERACTIVE in false true; do
  for ((kind = 0; kind < 6; kind++)); do
    [ "$selected_case" = all ] || [ "$selected_case" = "${names[$kind]}" ] || continue
    for action in update remove; do
      [ "$selected_action" = all ] || [ "$selected_action" = "$action" ] || continue
      CASE_NAME="${names[$kind]} $action interactive=$INTERACTIVE"
      file="${files[$kind]}"; header="${headers[$kind]}"
      # Quoted mixed-case keys and CRLF are accepted persisted CSV, and an
      # unrelated row must retain both its spelling and value after mutation.
      printf '%s\r\n"MiXeD.Example.Com","%s"\r\nOther.Example.Com,%s\r\n' \
        "$header" "${old_values[$kind]}" "${old_values[$kind]}" >"$file"
      validate_settings_for_render || fail_test "Valid mixed-case fixture rejected: $CASE_NAME"
      if [ "$action" = update ]; then
        if ! run_command "set-${commands[$kind]}" MIXED.EXAMPLE.COM "${new_values[$kind]}" >"$TEST_ROOT/command.log" 2>&1; then
          cat "$TEST_ROOT/command.log" >&2
          fail_test "Mixed-case update failed: $CASE_NAME"
        fi
        expected="${header}"$'\n'"mixed.example.com,${new_values[$kind]}"$'\n'"Other.Example.Com,${old_values[$kind]}"
        assert_contents "$file" "$expected"
        expect_value "${read_values[$kind]}" "${getters[$kind]}" mixed.example.com
        # Repeating the update with another spelling cannot add a logical row.
        run_command "set-${commands[$kind]}" Mixed.Example.Com "${new_values[$kind]}" >"$TEST_ROOT/command.log" 2>&1
        assert_contents "$file" "$expected"
      else
        run_command "remove-${commands[$kind]}" MIXED.EXAMPLE.COM >"$TEST_ROOT/command.log" 2>&1
        assert_contents "$file" "${header}"$'\n'"Other.Example.Com,${old_values[$kind]}"
      fi
      validate_settings_for_render || fail_test "Mutation left invalid or duplicate state: $CASE_NAME"
      printf '[tests] PASS: %s\n' "$CASE_NAME"
      printf '%s\n' "$header" >"$file"
    done
  done

  if [ "$selected_case" = all ] || [ "$selected_case" = inheritance ]; then
    for action in update remove; do
      [ "$selected_action" = all ] || [ "$selected_action" = "$action" ] || continue
      CASE_NAME="inheritance $action interactive=$INTERACTIVE"
      printf '%s\r\n"MiXeD.Example.Com",no,yes,no,yes,no\r\nOther.Example.Com,yes,no,yes,no,yes\r\n' \
        "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" >"$INHERITANCE_FILE"
      validate_dedicated_host_inheritance_state || fail_test "Mixed-case inheritance fixture rejected"
      if [ "$action" = update ]; then
        if ! run_command set-dedicated-host-inherit MIXED.EXAMPLE.COM headers no >"$TEST_ROOT/command.log" 2>&1; then
          cat "$TEST_ROOT/command.log" >&2
          fail_test "Mixed-case inheritance update failed: $CASE_NAME"
        fi
        expected="${STATE_DEDICATED_HOST_INHERITANCE_HEADER}"$'\n'"mixed.example.com,no,yes,no,no,no"$'\n'"Other.Example.Com,yes,no,yes,no,yes"
        assert_contents "$INHERITANCE_FILE" "$expected"
        expect_value no get_dedicated_host_inheritance mixed.example.com headers
        expect_value yes get_dedicated_host_inheritance mixed.example.com acl
        run_command set-dedicated-host-inherit Mixed.Example.Com headers no >"$TEST_ROOT/command.log" 2>&1
        assert_contents "$INHERITANCE_FILE" "$expected"
      else
        remove_dedicated_host_inheritance MIXED.EXAMPLE.COM
        assert_contents "$INHERITANCE_FILE" "${STATE_DEDICATED_HOST_INHERITANCE_HEADER}"$'\n'"Other.Example.Com,yes,no,yes,no,yes"
        expect_value yes get_dedicated_host_inheritance mixed.example.com mtls
      fi
      validate_dedicated_host_inheritance_state || fail_test "Inheritance mutation left duplicate state"
      printf '[tests] PASS: %s\n' "$CASE_NAME"
      printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" >"$INHERITANCE_FILE"
    done
  fi
done

if [ "$selected_case" = all ]; then
  CASE_NAME='mixed-case explicit ACL overrides remain explicit'
  printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" MiXeD.Example.Com,allow >"$BACKEND_ACL_POLICY_FILE"
  printf '%s\n' "$STATE_BACKEND_ACL_STATUSES_HEADER" MiXeD.Example.Com,451 >"$BACKEND_ACL_STATUS_FILE"
  _sr_has_backend_acl_policy_override mixed.example.com || fail_test 'Mixed-case explicit ACL policy was treated as inherited'
  _sr_has_backend_acl_status_override mixed.example.com || fail_test 'Mixed-case explicit ACL status was treated as inherited'
  printf '[tests] PASS: %s\n' "$CASE_NAME"

  CASE_NAME='generic CSV keys retain case sensitivity'
  generic="$CONFIG_DIR/generic.csv"
  printf '%s\n' domain,value Token,UPPER token,lower >"$generic"
  state_csv_upsert_two_col_value "$generic" domain,value token updated
  assert_contents "$generic" $'domain,value\nToken,UPPER\ntoken,updated'
  state_csv_delete_two_col_key "$generic" domain,value Token
  assert_contents "$generic" $'domain,value\ntoken,updated'
  printf '%s\n' kind,name,value Path,Name,UPPER path,name,lower >"$generic"
  state_csv_upsert_row_by_keys "$generic" kind,name,value 3 2 path name -- path name updated
  assert_contents "$generic" $'kind,name,value\nPath,Name,UPPER\npath,name,updated'
  state_csv_has_row_by_keys "$generic" kind,name,value 3 2 Path Name || fail_test 'Exact generic key was not found'
  if state_csv_has_row_by_keys "$generic" kind,name,value 3 2 PATH NAME; then
    fail_test 'Generic key existence became case-insensitive'
  fi
  state_csv_delete_by_keys "$generic" kind,name,value 3 2 Path Name
  assert_contents "$generic" $'kind,name,value\npath,name,updated'
  printf '[tests] PASS: %s\n' "$CASE_NAME"
fi

printf '%s\n' 'persisted_override_mutation.sh: PASS'
