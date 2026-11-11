#!/usr/bin/env bash
# Fixture runtime variables are consumed by sourced command implementations.
# shellcheck disable=SC2034
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils security_rules domain_config ports access_log cli/command_visibility cli/run_command; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-numeric.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; TMP_DIR="$TEST_WORK/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
state_csv_ensure_all_state_files
INTERACTIVE=false VERBOSE=false
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function reject_test() { if ( "$@" ) >"$TEST_WORK/rejected" 2>&1; then fail_test "Unexpected success: $*"; fi; }
function _config_begin_transaction_if_needed() { :; }
function _config_end_transaction_if_started() { :; }
function create_backup() { :; }
function create_nginx_config() { :; }
function update_nginx_config_for_security_change() { :; }
function update_nginx_config() { :; }
function audit_log() { :; }
function log_msg() { :; }
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 127.0.0.1:80 dockistrate-net >>"$BACKEND_PORTS_FILE"

# Range checking happens before arithmetic, including values that would wrap.
for pair in '010 10' '08 8' '00080 80' '08080 8080' '065535 65535'; do
  read -r raw expected <<<"$pair"
  is_valid_port "$raw" || fail_test "Rejected decimal port $raw"
  [ "$(normalize_port "$raw")" = "$expected" ] || fail_test "Wrong decimal port $raw"
  [ "$(normalize_validated_value is_valid_port "$raw")" = "$expected" ] || fail_test 'Prompt normalization differs'
done
for raw in '' 0 00 -1 65536 0100000 18446744073709551617 1e2 '1+2' '$(false)'; do reject_test is_valid_port "$raw"; done
reject_test normalize_positive_decimal 9223372036854775808
[ "$(normalize_positive_decimal 0009223372036854775807)" = 9223372036854775807 ] || fail_test 'Lost integer boundary'
reject_test validate_http_port_combination http 0443

function seed_rules() {
  local enabled="$1" i=0
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$SECURITY_RULES_DB"
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_DB"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    _sr_write_db_line_with_action block "$enabled" example.com single 403 1 "rule-$i" auto header X-Case equals "blocked-$i" >>"$SECURITY_RULES_DB"
    csv_join_row "$enabled" example.com l7 deny "203.0.113.$i" 403 >>"$SECURITY_IP_RULES_DB"
  done
}
function assert_policy_result() {
  local family="$1" operation="$2" wanted="$3" file="$SECURITY_RULES_DB" field=8 line='' ordinal=0 identity=0 changed=0
  [ "$family" != acl ] || { file="$SECURITY_IP_RULES_DB"; field=4; }
  while IFS= read -r line; do
    ordinal=$((ordinal + 1)); [ "$ordinal" -gt 1 ] || continue
    csv_parse_line "$line"
    identity="${CSV_FIELDS[field]##*-}"; identity="${identity##*.}"
    case "$operation" in
    disable | enable)
      expected=1; [ "$operation" != enable ] || expected=0
      if [ "$identity" -eq "$wanted" ]; then expected=$((1 - expected)); changed=$((changed + 1)); fi
      [ "${CSV_FIELDS[0]}" = "$expected" ] || fail_test "$family $operation changed the wrong row"
      ;;
    update)
      value="${CSV_FIELDS[45]:-}"; [ "$family" != acl ] || value="${CSV_FIELDS[3]}"
      if [ "$identity" -eq "$wanted" ]; then
        expected=updated; [ "$family" != acl ] || expected=allow
        [ "$value" = "$expected" ] || fail_test "$family update missed intended row"; changed=$((changed + 1))
      else
        expected="rule-$identity"; [ "$family" != acl ] || expected=deny
        [ "$value" = "$expected" ] || fail_test "$family update changed another row"
      fi
      ;;
    remove) [ "$identity" -ne "$wanted" ] || fail_test "$family removed the wrong row" ;;
    move) if [ "$ordinal" -eq 2 ]; then [ "$identity" -eq "$wanted" ] || fail_test "$family moved the wrong row"; fi ;;
    esac
  done <"$file"
  expected=11; [ "$operation" != remove ] || expected=10
  [ "$ordinal" -eq "$expected" ] || fail_test "$family $operation lost/duplicated rows"
  case "$operation" in disable | enable | update) [ "$changed" -eq 1 ] || fail_test 'Did not change exactly one intended row' ;; esac
}
for raw in 010 08 10; do
  wanted="$(normalize_positive_decimal "$raw")"
  for family in security acl; do
    for operation in disable enable update remove move; do
      initial=1; [ "$operation" != enable ] || initial=0
      seed_rules "$initial"
      command="$operation-security-rule"; [ "$family" != acl ] || command="$operation-acl"
      [ "$family:$operation" != acl:move ] || command=move-acl-rule
      args=("$raw")
      case "$operation" in
      update) args+=(--reason updated); [ "$family" != acl ] || args=("$raw" --action allow) ;;
      move) args+=(01) ;;
      esac
      ( _run_command_impl "$command" "${args[@]}" ) >"$TEST_WORK/command" 2>&1 || { cat "$TEST_WORK/command" >&2; fail_test "$command $raw failed"; }
      assert_policy_result "$family" "$operation" "$wanted"
    done
  done
done
seed_rules 1
cp "$SECURITY_RULES_DB" "$TEST_WORK/original"
reject_test _run_command_impl disable-security-rule 18446744073709551617
cmp -s "$SECURITY_RULES_DB" "$TEST_WORK/original" || fail_test 'Oversized ID mutated rules'

# The former mixed-base move duplicated field8 and dropped field10.
for raw in 010 08; do
  printf '%s\n' "$STATE_ACCESS_LOG_FIELDS_HEADER" >"$ACCESS_LOG_FIELDS_FILE"
  for i in 1 2 3 4 5 6 7 8 9 10; do printf 'field-%s\n' "$i" >>"$ACCESS_LOG_FIELDS_FILE"; done
  wanted="$(normalize_positive_decimal "$raw")"
  _run_command_impl update-log-field "$raw" updated >"$TEST_WORK/log-command"
  [ "$(sed -n "$((wanted + 1))p" "$ACCESS_LOG_FIELDS_FILE")" = updated ] || fail_test 'Updated wrong log field'
  _run_command_impl move-log-field "$raw" 01 >"$TEST_WORK/log-command"
  [ "$(sed -n '2p' "$ACCESS_LOG_FIELDS_FILE")" = updated ] || fail_test 'Moved wrong log field'
  [ "$(sort -u "$ACCESS_LOG_FIELDS_FILE" | wc -l | tr -d ' ')" = 11 ] || fail_test 'Log move lost/duplicated data'
  _run_command_impl remove-log-field 01 >"$TEST_WORK/log-command"
  [ "$(wc -l <"$ACCESS_LOG_FIELDS_FILE" | tr -d ' ')" = 10 ] || fail_test 'Log removal count'
done

# Exercise the real sorter, retaining the emitted path/target boundary.
source "$ROOT_DIR/lib/nginx/_emit_path_locations.sh"
function _write_location_block() { printf '%s|%s\n' "$2" "${13:-}" >>"$1"; }
for priority in 010 08; do
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  state_backend_ports_row_path example.com '/api/.*' '' 80 inherit inherit '' regex "$priority" api.example.com:8080 none - auto >>"$BACKEND_PORTS_FILE"
  state_backend_ports_row_path example.com '/.*' '' 80 inherit inherit '' regex 9 fallback.example.com:8080 none - auto >>"$BACKEND_PORTS_FILE"
  : >"$TEST_WORK/locations"
  _emit_path_locations "$TEST_WORK/locations" example.com 80 127.0.0.1:80 no off '' '' '' http1.1
  expected='/.*|fallback.example.com:8080'; [ "$priority" != 08 ] || expected='/api/.*|api.example.com:8080'
  [ "$(head -n 1 "$TEST_WORK/locations")" = "$expected" ] || fail_test 'Octal path priority changed precedence'
done
printf '[PASS] Decimal numeric operands preserve selected rules, log fields and path ordering\n'
