#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=helpers/interactive_audit_fixture.sh
source "$ROOT_DIR/tests/helpers/interactive_audit_fixture.sh"
printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" \
  '1,dedicated.example.com,l7,allow,203.0.113.1,' \
  '1,primary.example.com,l7,deny,203.0.113.8,403' >"$SECURITY_IP_RULES_DB"

# Real menu/read/review path: global ID2, alias, both, allow, new exact IP, Run.
prompt_args_for_command update-acl < <(printf '2\n2\n4\n2\n203.0.113.9\n\n') || fail_test 'Update ACL collection failed'
[ "$SELECTED_CMD" = update-acl ] || fail_test 'Wrong selected command'
[ "${SELECTED_ARGS[*]}" = '2 --domain alias.example.com --scope both --action allow --ip 203.0.113.9' ] || fail_test 'Update ACL flags lost selected edits'
summary="$(_review_command_format_arg_summary "$SELECTED_CMD" "${SELECTED_ARGS[@]}")"
[[ "$summary" == *'Domain: alias.example.com'* && "$summary" == *'IP or CIDR: 203.0.113.9'* ]] || fail_test 'ACL review does not explain selected changes'
_run_command_impl "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
[ "$(_sr_ip_load_line 1)" = '1,dedicated.example.com,l7,allow,203.0.113.1,' ] || fail_test 'Other global ID changed'
[ "$(_sr_ip_load_line 2)" = '1,alias.example.com,both,allow,203.0.113.9,403' ] || fail_test 'Edited row differs'

# Keep identity/scope/IP, switch back to deny and explicitly clear its override.
prompt_args_for_command update-acl < <(printf '2\n\n\n3\n\n-\n\n') || fail_test 'Clear-status collection failed'
_run_command_impl "$SELECTED_CMD" "${SELECTED_ARGS[@]}"
[ "$(_sr_ip_load_line 2)" = '1,alias.example.com,both,deny,203.0.113.9,' ] || fail_test 'Blank override was not cleared'

# EOF must abandon collection before a command can be selected or dispatched.
if prompt_args_for_command update-acl < <(printf '2\n\n\n\n'); then fail_test 'EOF accepted as a current IP'; fi
[ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" -eq 0 ] || fail_test 'EOF retained command selection'
if prompt_args_for_command update-acl < <(printf '2\n\n\n\n\n\n'); then fail_test 'Unchanged ACL claimed an update'; fi
echo '[tests] interactive_acl_update.sh: PASS'
