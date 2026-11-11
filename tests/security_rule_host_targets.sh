#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils security_rules domain_config cli/arg_choices_misc cli/arg_choices_security cli/get_arg_choices cli/security_rule_interactive_common; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-rule-hosts.XXXXXXXX")"
trap 'rm -rf "$test_root"' EXIT
STATE_DIR="$test_root/state" TMP_DIR="$test_root/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
state_csv_ensure_all_state_files
printf '2\n' >"$CONFIG_DIR/state_schema_version"
state_backend_ports_row_backend primary.example.com 127.0.0.1:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'alias,alias.example.com,primary.example.com' \
  'dedicated,dedicated.example.com,primary.example.com' >"$BACKEND_ALIASES_FILE"
cp "$BACKEND_ALIASES_FILE" "$test_root/aliases"
mkdir -p "$STATE_DIR/domains/cert.example.com/runtime/applied" "$STATE_DIR/domains/draft.example.com/config"
printf 'key,value\nschema_version,2\nrole,certificate-only\n' >"$STATE_DIR/domains/cert.example.com/runtime/applied/domain.csv"
printf 'key,value\nschema_version,2\nrole,backend\n' >"$STATE_DIR/domains/draft.example.com/config/domain.csv"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
REMOVE_AT_BEGIN=false
function _config_begin_transaction_if_needed() {
  : >"$test_root/transaction-started"
  if [ "$REMOVE_AT_BEGIN" = true ]; then printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"; fi
}
function _config_end_transaction_if_started() { :; }
function transaction_return_failure() { :; }
function create_backup() { :; }
function update_nginx_config_for_security_change() { :; }

for target in primary.example.com alias.example.com dedicated.example.com; do
  _sr_assert_domain_exists "$target"
  add_security_rule "$target" 1 path - equals /private >/dev/null
done
[ "$(awk 'END {print NR}' "$SECURITY_RULES_DB")" -eq 4 ] || fail_test 'Supported host rules were not saved'
update_security_rule 1 --domain DEDICATED.EXAMPLE.COM >/dev/null
csv_parse_line "$(_sr_load_line 1)"
[ "${CSV_FIELDS[1]}" = dedicated.example.com ] || fail_test 'Rule update lost normalized host target'

for target in cert.example.com draft.example.com missing.example.com; do
  rm -f "$test_root/transaction-started"
  if (add_security_rule "$target" 1 path - equals /private) >"$test_root/rejected" 2>&1; then fail_test "Accepted unsupported target $target"; fi
  [ ! -e "$test_root/transaction-started" ] || fail_test 'Rejected target began a transaction'
  if (update_security_rule 1 --domain "$target") >"$test_root/rejected" 2>&1; then fail_test "Updated rule to unsupported target $target"; fi
done

# Removal between initial parsing and the lock must reject before rule writes.
for operation in add update; do
  cp "$test_root/aliases" "$BACKEND_ALIASES_FILE"
  cp "$SECURITY_RULES_DB" "$test_root/rules-before"
  REMOVE_AT_BEGIN=true
  if [ "$operation" = add ]; then
    if add_security_rule alias.example.com 1 path - equals /private >"$test_root/rejected" 2>&1; then fail_test 'Add ignored host removal under lock'; fi
  else
    if update_security_rule 1 --domain alias.example.com >"$test_root/rejected" 2>&1; then fail_test 'Update ignored host removal under lock'; fi
  fi
  cmp -s "$SECURITY_RULES_DB" "$test_root/rules-before" || fail_test 'Removed target changed rule state'
done
REMOVE_AT_BEGIN=false
cp "$test_root/aliases" "$BACKEND_ALIASES_FILE"

expected=$'alias.example.com\ndedicated.example.com\nprimary.example.com'
for command in add-security-rule update-security-rule; do
  # The production function is sourced above; the final fallback test replaces it.
  # shellcheck disable=SC2218
  [ "$(get_arg_choices "$command" domain)" = "$expected" ] || fail_test "$command interactive choices differ from supported hosts"
done
__dockistrate_completion_handlers=()
source "$ROOT_DIR/completion/commands/__dockistrate_backend_domains.sh"
source "$ROOT_DIR/completion/commands/__dockistrate_complete_backend_domains.sh"
source "$ROOT_DIR/completion/commands/_dockistrate_complete_backend_domain_commands.sh"
for command in add-security-rule update-security-rule; do
  cur='' cword=2 prev=''
  if [ "$command" = update-security-rule ]; then cword=4; prev=--domain; fi
  COMPREPLY=()
  _dockistrate_complete_backend_domain_commands "$command" || fail_test 'Host completion was not handled'
  [ "${COMPREPLY[*]}" = 'alias.example.com dedicated.example.com primary.example.com' ] || fail_test 'Host completion included a draft/certificate or omitted a serving host'
done

function _sr_prompt_choice() { printf -v "$1" '%s' dedicated.example.com; }
selected=''
_sr_prompt_domain selected add-security-rule
[ "$selected" = dedicated.example.com ] || fail_test 'Interactive selector lost dedicated host'
# The manual fallback follows the same host existence policy.
function get_arg_choices() { :; }
function read_with_editing() { printf -v "$2" '%s' alias.example.com; }
function is_back_input() { return 1; }
_sr_prompt_domain selected add-security-rule
[ "$selected" = alias.example.com ] || fail_test 'Manual selector rejected ordinary alias'

printf '[tests] security_rule_host_targets.sh: PASS\n'
