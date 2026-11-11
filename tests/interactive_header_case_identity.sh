#!/usr/bin/env bash
# Fixture state and prompt arrays are consumed by sourced modules.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils headers domain_config cli/arg_choices_misc cli/prompt_args_handlers_defaults \
  cli/prompt_args_handlers_headers cli/cmd_requires_existing_backend cli/has_backends cli/interactive_no_state \
  cli/read_lines_into_array cli/choose_http_domain cli/pre_runtime_commands; do
  source "$ROOT_DIR/lib/$module.sh"
done
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-header-prompts.XXXXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STATE_DIR="$WORK/state"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR"
printf '5\n' >"$CONFIG_DIR/state_schema_version"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

for domain in example.com alias.example.com; do
  domain_config_write_template "$domain" backend "$STATE_DIR/domains/$domain/runtime/applied"
done
applied="$STATE_DIR/domains/example.com/runtime/applied"
csv_join_row response X-Example 'first, "quoted" \\value' >>"$applied/headers.csv"
csv_join_row response x-example 'first, "quoted" \\value' >>"$applied/headers.csv"
csv_join_row request X-Example request-value >>"$applied/headers.csv"
csv_join_row response Content-Security-Policy 'quoted "a" \\tail' >>"$applied/headers.csv"
csv_join_row response content-security-policy 'quoted "a" \\tail' >>"$applied/headers.csv"
csv_join_row response X-Conflict first >>"$applied/headers.csv"
csv_join_row response x-conflict second >>"$applied/headers.csv"
csv_join_row response Content-Security-Policy one >>"$STATE_DIR/domains/alias.example.com/runtime/applied/headers.csv"
csv_join_row response content-security-policy two >>"$STATE_DIR/domains/alias.example.com/runtime/applied/headers.csv"
_domain_config_copy_inputs "$applied" "$STATE_DIR/domains/example.com/config"
printf 'unfinished,"draft\n' >>"$STATE_DIR/domains/example.com/config/headers.csv"
cp "$applied/headers.csv" "$WORK/applied-before"
cp "$STATE_DIR/domains/example.com/config/headers.csv" "$WORK/draft-before"

# Shared column order remains flexible, and names retain their first spelling.
printf 'header_value,header_name,header_type\n' >"$CUSTOM_HEADERS_FILE"
csv_join_row global-value X-Global response >>"$CUSTOM_HEADERS_FILE"
csv_join_row global-value x-global response >>"$CUSTOM_HEADERS_FILE"
csv_join_row 'max-age=100' strict-transport-security response >>"$CUSTOM_HEADERS_FILE"
cp "$CUSTOM_HEADERS_FILE" "$WORK/global-before"
[ "$(__arg_choices_custom_header_names response)" = $'X-Global\nstrict-transport-security' ] || fail_test 'Global names were not coalesced with first spelling'
[ "$(__arg_choices_backend_header_names EXAMPLE.COM response)" = $'X-Example\nContent-Security-Policy\nX-Conflict' ] || fail_test 'Applied names were not coalesced or the pending draft was read'
[ "$(__arg_choices_backend_header_names example.com request)" = X-Example ] || fail_test 'Request and response choices were combined'

PROMPT_ARGS_CONTEXT=(response X-GLOBAL)
[ "$(prompt_args_compute_default update-header value '')" = global-value ] || fail_test 'Global default lookup remained case sensitive'
PROMPT_ARGS_CONTEXT=(example.com response x-EXAMPLE)
[ "$(prompt_args_compute_default update-backend-header value '')" = 'first, "quoted" \\value' ] || fail_test 'Applied default lost exact header data'
PROMPT_ARGS_CONTEXT=(example.com response X-CONFLICT)
[ -z "$(prompt_args_compute_default update-backend-header value '' 2>"$WORK/conflict")" ] || fail_test 'Conflicting values chose an arbitrary default'
grep -Fq 'enter a replacement value' "$WORK/conflict" || fail_test 'Conflicting default lacked repair guidance'
[ "$(_prompt_args_header_value example.com response Strict-Transport-Security global)" = max-age=100 ] || fail_test 'HSTS global fallback ignored capitalization'

summary="$(_prompt_args_backend_csp_summary)"
[ "$summary" = $'  alias.example.com=<conflicting values; set a replacement>\n  example.com=quoted "a" \\\\tail' ] || fail_test 'CSP summary lost literal content or duplicate identity'

# The aggregate cache is absent: all repair choices still come from applied files.
[ ! -e "$BACKEND_HEADERS_FILE" ] && [ ! -e "$BACKEND_PORTS_FILE" ] || fail_test 'Fixture unexpectedly has derived cache files'
interactive_command_availability update-backend-header || fail_test 'Missing cache hid an available repair command'
[ "$(__arg_choices_domain remove-backend-header)" = $'alias.example.com\nexample.com' ] || fail_test 'Removal owners were read from stale cache'
function choose_option() { printf -v "$1" '%s' 1; }
selected_domain=''
choose_http_domain selected_domain
[ "$selected_domain" = example.com ] || fail_test 'Specialized header picker did not use applied owners'

# A new menu starts with default visibility. Header preparation must read the
# stored policy before prompts display values, without preparing live runtime.
VISIBILITY_POLICY=redacted
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
cp "$GLOBAL_SETTINGS_FILE" "$WORK/settings-before"
VISIBILITY_POLICY=full
dockistrate_prepare_header_command update-backend-header
[ "$VISIBILITY_POLICY" = redacted ] || fail_test 'Header preparation ignored persisted redacted visibility'
summary="$(_prompt_args_backend_csp_summary)"
[[ "$summary" == *'[REDACTED]'* ]] || fail_test 'Prepared header summary did not redact stored values'
[[ "$summary" != *'quoted "a"'* ]] || fail_test 'Prepared header summary leaked a stored value'
cmp -s "$GLOBAL_SETTINGS_FILE" "$WORK/settings-before" || fail_test 'Read-only header preparation rewrote global settings'

cmp -s "$applied/headers.csv" "$WORK/applied-before" || fail_test 'Prompts rewrote applied headers'
cmp -s "$STATE_DIR/domains/example.com/config/headers.csv" "$WORK/draft-before" || fail_test 'Prompts rewrote pending draft'
cmp -s "$CUSTOM_HEADERS_FILE" "$WORK/global-before" || fail_test 'Prompts rewrote shared headers'
[ ! -e "$BACKEND_HEADERS_FILE" ] && [ ! -e "$BACKEND_PORTS_FILE" ] || fail_test 'Prompts published derived cache files'
printf '[PASS] Header prompt identity, repair choices, literal defaults, and read-only applied state\n'
