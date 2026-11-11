#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers/interactive_audit_fixture.sh
source "$ROOT_DIR/tests/helpers/interactive_audit_fixture.sh"

function expect_cancel() {
  if "$@"; then fail_test "EOF accepted by $*"; fi
}
function expect_no_selection() {
  [ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'Cancelled prompt retained a command'
}
result=''
expect_cancel _sr_prompt_count result 1 </dev/null
expect_cancel _sr_prompt_code_optional result </dev/null
expect_cancel _sr_prompt_domain result add-backend </dev/null
expect_cancel prompt_input_valid result 'Port' 80 is_valid_port </dev/null

# Empty Enter is a real answer; it still selects the documented defaults.
_sr_prompt_count result 3 < <(printf '\n')
[ "$result" = 3 ] || fail_test 'Enter no longer retains condition count'
_sr_prompt_code_optional result < <(printf '\n')
[ -z "$result" ] || fail_test 'Empty optional status became a cancellation'
INTERACTIVE=false
prompt_input result Port 80 </dev/null
[ "$result" = 80 ] || fail_test 'Noninteractive default changed'
INTERACTIVE=true

# Actual source/operator choosers and required text reads; restrict only the
# offered source list so each missing-name/value branch is exercised directly.
function __arg_choices_source() { printf '%s\n' "$TEST_SOURCE"; }
for TEST_SOURCE in header cookie arg var; do
  expect_cancel _sr_collect_condition_quads add-security-rule 1 < <(printf '\n')
done
TEST_SOURCE=method
expect_cancel _sr_collect_condition_quads add-security-rule 1 < <(printf '\n\n')
expect_cancel _collect_update_port_choose_from_lines result Port '__MANUAL__|Enter manually' 80 Port < <(printf '\n')
expect_cancel _collect_update_port_choose_from_lines result Port '80|HTTP' 80 Port </dev/null
expect_cancel _prompt_nginx_directive_pick_value result Directive '' true < <(printf '\n')

# Collection clears selection rather than publishing partially collected args.
expect_cancel prompt_args_for_command add-acl < <(printf '3\n\n1\n')
expect_no_selection
expect_cancel prompt_args_for_command set-hsts </dev/null
expect_no_selection
expect_cancel prompt_args_for_command set-backend-csp < <(printf '2\n')
expect_no_selection
echo '[tests] interactive_specialized_eof.sh: PASS'
