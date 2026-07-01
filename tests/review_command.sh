#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/operator_visibility.sh
source "$ROOT_DIR/lib/utils/operator_visibility.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"

SELECTED_CMD=""
SELECTED_ARGS=()
CHOICE_QUEUE=()
CHOICE_CURSOR=0
CHOICE_CALLS=0
LAST_CHOICE_PROMPT=""
READ_QUEUE=()
READ_CURSOR=0
DEFAULT_VISIBILITY_POLICY="full"
VISIBILITY_POLICY="full"

function reset_review_test() {
  SELECTED_CMD=""
  SELECTED_ARGS=()
  CHOICE_QUEUE=("$@")
  CHOICE_CURSOR=0
  CHOICE_CALLS=0
  LAST_CHOICE_PROMPT=""
  READ_QUEUE=()
  READ_CURSOR=0
}

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  mutating-test)
    printf '%s' 'first,;second,'
    ;;
  remove-backend)
    printf '%s' 'domain,'
    ;;
  start-nginx)
    printf '%s' 'nginx_image,nginx:latest;docker_opts,'
    ;;
  add-backend)
    printf '%s' 'domain,;image,;container_port,;protocol,http;listen,;cert_path,;ws,no;docker_opts,;network,dockistrate-net;expose,yes'
    ;;
  set-nginx-docker-opts)
    printf '%s' 'docker_opts,'
    ;;
  add-header)
    printf '%s' 'req_resp,request;header,;value,'
    ;;
  set-hsts)
    printf '%s' 'hsts_value,'
    ;;
  set-csp)
    printf '%s' 'csp_value,'
    ;;
  *)
    return 1
    ;;
  esac
}

function choose_option() {
  local __idx_var="${1:-}"
  LAST_CHOICE_PROMPT="${2:-}"
  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    echo "[Error] choose_option called unexpectedly or queue exhausted." >&2
    exit 1
  fi
  CHOICE_CALLS=$((CHOICE_CALLS + 1))
  printf -v "$__idx_var" '%s' "${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  return 0
}

function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}" value=""
  value="$default"
  if [ "$READ_CURSOR" -lt "${#READ_QUEUE[@]}" ]; then
    value="${READ_QUEUE[$READ_CURSOR]}"
  fi
  READ_CURSOR=$((READ_CURSOR + 1))
  printf -v "$__var" '%s' "$value"
}

if command_is_mutating status; then
  echo "[Error] status should be read-only." >&2
  exit 1
fi
if ! command_is_mutating add-port; then
  echo "[Error] add-port should be mutating." >&2
  exit 1
fi
if ! command_is_destructive remove-backend; then
  echo "[Error] remove-backend should be destructive." >&2
  exit 1
fi
if command_is_destructive stop-backend; then
  echo "[Error] stop-backend should require review without exact YES destructive confirmation." >&2
  exit 1
fi

quoted="$(format_cli_equivalent add-port "example.com" "hello world" "a'b")"
expected="./dockistrate.sh add-port example.com 'hello world' 'a'\\''b'"
if [ "$quoted" != "$expected" ]; then
  echo "[Error] CLI equivalent escaping mismatch." >&2
  echo "Expected: $expected" >&2
  echo "Actual:   $quoted" >&2
  exit 1
fi
quoted="$(format_cli_equivalent add-backend $'line one\nline two')"
expected="./dockistrate.sh add-backend \$'line one\\nline two'"
if [ "$quoted" != "$expected" ]; then
  echo "[Error] CLI equivalent multiline escaping mismatch." >&2
  echo "Expected: $expected" >&2
  echo "Actual:   $quoted" >&2
  exit 1
fi

reset_review_test
if ! review_command_before_run status >/dev/null; then
  echo "[Error] read-only command should bypass review." >&2
  exit 1
fi
if [ "$CHOICE_CALLS" -ne 0 ]; then
  echo "[Error] read-only review should not render choices." >&2
  exit 1
fi

reset_review_test 2
SELECTED_CMD="mutating-test"
SELECTED_ARGS=("one" "two")
set +e
review_command_before_run mutating-test "one" "two" >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ] || [ -n "${SELECTED_CMD:-}" ] || [ "${#SELECTED_ARGS[@]}" -ne 0 ]; then
  echo "[Error] Cancel should clear selected command and args." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"CLI equivalent:"* ]] || [[ "$LAST_CHOICE_PROMPT" != *"first: one"* ]]; then
  echo "[Error] Review details should be rendered in the choose_option prompt before the menu." >&2
  exit 1
fi

reset_review_test 1
set +e
review_command_before_run mutating-test "one" "two" >/dev/null
status=$?
set -e
if [ "$status" -ne 2 ]; then
  echo "[Error] Edit previous answers should return status 2." >&2
  exit 1
fi

reset_review_test 0
READ_QUEUE=("no")
set +e
review_command_before_run remove-backend example.com >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ]; then
  echo "[Error] Destructive command should require exact YES confirmation." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"[Warn] This command can remove or revoke existing state."* ]]; then
  echo "[Error] Destructive review prompt should include an impact warning." >&2
  exit 1
fi

reset_review_test 0
READ_QUEUE=("YES")
if ! review_command_before_run remove-backend example.com >/dev/null; then
  echo "[Error] Destructive command should run after exact YES confirmation." >&2
  exit 1
fi

reset_review_test 0
if ! review_command_before_run mutating-test $'line one\nline two' "plain" >/dev/null; then
  echo "[Error] Mutating command with multiline args should run after review Run." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"line one\\nline two"* ]]; then
  echo "[Error] Multiline review args should render with visible newline escapes." >&2
  exit 1
fi

reset_review_test 0
if ! review_command_before_run mutating-test $'col1\tcol2' "plain" >/dev/null; then
  echo "[Error] Mutating command with tab args should run after review Run." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"col1\\tcol2"* ]]; then
  echo "[Error] Tab in review args should render as visible \\t escape." >&2
  exit 1
fi

reset_review_test 0
if ! review_command_before_run add-backend dvwa.com httpd:latest 80 https 443 selfsigned no "" dockistrate-net yes yes 443 >/dev/null; then
  echo "[Error] add-backend review should run after Review Run." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" == *"Argument 11"* ]] || [[ "$LAST_CHOICE_PROMPT" == *"Argument 12"* ]]; then
  echo "[Error] add-backend review should label redirect arguments instead of using numeric fallbacks." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"HTTP redirect: yes"* ]] || [[ "$LAST_CHOICE_PROMPT" != *"Redirect target port: 443"* ]]; then
  echo "[Error] add-backend review should include friendly redirect labels." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"./dockistrate.sh add-backend dvwa.com httpd:latest 80 https --listen 443 --cert selfsigned --ws no --network dockistrate-net --expose yes"* ]]; then
  echo "[Error] add-backend review should render a flag-based CLI equivalent." >&2
  printf '%s\n' "$LAST_CHOICE_PROMPT" >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"./dockistrate.sh add-port dvwa.com 80 80 http none no"* ]]; then
  echo "[Error] add-backend review should render the HTTP mapping needed before redirect." >&2
  printf '%s\n' "$LAST_CHOICE_PROMPT" >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"./dockistrate.sh set-port-redirect dvwa.com 80 on 301:443"* ]]; then
  echo "[Error] add-backend review should render the redirect follow-up CLI equivalent." >&2
  printf '%s\n' "$LAST_CHOICE_PROMPT" >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *$'\n  ./dockistrate.sh add-port dvwa.com 80 80 http none no'* ]] ||
  [[ "$LAST_CHOICE_PROMPT" != *$'\n  ./dockistrate.sh set-port-redirect dvwa.com 80 on 301:443'* ]]; then
  echo "[Error] Multi-line CLI equivalents should remain indented." >&2
  printf '%s\n' "$LAST_CHOICE_PROMPT" >&2
  exit 1
fi

reset_review_test 0
if ! review_command_before_run mutating-test >/dev/null; then
  echo "[Error] Mutating command with no args should run after review Run." >&2
  exit 1
fi
if [[ "$LAST_CHOICE_PROMPT" != *"  (none)"* ]]; then
  echo "[Error] No-arg review should render an empty argument summary." >&2
  exit 1
fi

VISIBILITY_POLICY="redacted"
redacted_cli="$(format_cli_equivalent start-nginx --nginx-image nginx:mainline --docker-opts "--env SECRET=top")"
if [[ "$redacted_cli" == *"SECRET=top"* ]] || [[ "$redacted_cli" != *"--docker-opts '[REDACTED]'"* ]] || [[ "$redacted_cli" != *"--nginx-image nginx:mainline"* ]]; then
  echo "[Error] Flag-style review CLI equivalent should redact docker opts without hiding non-sensitive option values." >&2
  echo "$redacted_cli" >&2
  exit 1
fi
redacted_unknown_cli="$(format_cli_equivalent start-nginx --unknown-flag nginx:mainline --docker-opts "--env UNKNOWN_SHIFT_SECRET=top")"
if [[ "$redacted_unknown_cli" == *"UNKNOWN_SHIFT_SECRET=top"* ]] ||
  [[ "$redacted_unknown_cli" != *"--unknown-flag nginx:mainline"* ]] ||
  [[ "$redacted_unknown_cli" != *"--docker-opts '[REDACTED]'"* ]]; then
  echo "[Error] Unknown long flags should not shift review redaction onto non-sensitive option values." >&2
  echo "$redacted_unknown_cli" >&2
  exit 1
fi
redacted_unquoted_docker_cli="$(format_cli_equivalent start-nginx --docker-opts --env UNQUOTED_DOCKER_SECRET=top)"
if [[ "$redacted_unquoted_docker_cli" == *"UNQUOTED_DOCKER_SECRET=top"* ]] ||
  [[ "$redacted_unquoted_docker_cli" == *"--env"* ]] ||
  [[ "$redacted_unquoted_docker_cli" != "./dockistrate.sh start-nginx --docker-opts '[REDACTED]'" ]]; then
  echo "[Error] Unquoted flag-style docker opts review output should hide trailing split words." >&2
  echo "$redacted_unquoted_docker_cli" >&2
  exit 1
fi
redacted_empty_flag_docker_cli="$(format_cli_equivalent start-nginx --docker-opts "" --env EMPTY_FLAG_SECRET=top)"
if [[ "$redacted_empty_flag_docker_cli" == *"EMPTY_FLAG_SECRET=top"* ]] ||
  [[ "$redacted_empty_flag_docker_cli" == *"--env"* ]] ||
  [[ "$redacted_empty_flag_docker_cli" != "./dockistrate.sh start-nginx --docker-opts '[REDACTED]'" ]]; then
  echo "[Error] Empty flag-style docker opts review output should hide trailing split words." >&2
  echo "$redacted_empty_flag_docker_cli" >&2
  exit 1
fi
redacted_summary="$(_review_command_format_arg_summary start-nginx --nginx-image nginx:mainline --docker-opts "--env SECRET=top")"
if [[ "$redacted_summary" == *"SECRET=top"* ]] || [[ "$redacted_summary" != *"[REDACTED]"* ]]; then
  echo "[Error] Flag-style review summary should redact docker opts." >&2
  echo "$redacted_summary" >&2
  exit 1
fi
redacted_add_backend_no_expose="$(format_cli_equivalent add-backend example.com nginx:alpine 80 http --docker-opts "--env REVIEW_BOUNDARY_SECRET=top" --no-expose)"
if [[ "$redacted_add_backend_no_expose" == *"REVIEW_BOUNDARY_SECRET=top"* ]] ||
  [[ "$redacted_add_backend_no_expose" != *"--docker-opts '[REDACTED]'"* ]] ||
  [[ "$redacted_add_backend_no_expose" != *"--no-expose"* ]]; then
  echo "[Error] add-backend review output should keep --no-expose after redacted docker opts." >&2
  echo "$redacted_add_backend_no_expose" >&2
  exit 1
fi
redacted_add_backend_no_expose_summary="$(_review_command_format_arg_summary add-backend example.com nginx:alpine 80 http --docker-opts "--env REVIEW_BOUNDARY_SECRET=top" --no-expose)"
if [[ "$redacted_add_backend_no_expose_summary" == *"REVIEW_BOUNDARY_SECRET=top"* ]] ||
  [[ "$redacted_add_backend_no_expose_summary" != *"[REDACTED]"* ]] ||
  [[ "$redacted_add_backend_no_expose_summary" != *"--no-expose"* ]]; then
  echo "[Error] add-backend review summary should keep --no-expose after redacted docker opts." >&2
  echo "$redacted_add_backend_no_expose_summary" >&2
  exit 1
fi
redacted_header_summary="$(_review_command_format_arg_summary add-header response X-Token Bearer SPLIT_HEADER_SECRET=top)"
if [[ "$redacted_header_summary" == *"SPLIT_HEADER_SECRET=top"* ]] || [[ "$redacted_header_summary" != *"[REDACTED]"* ]]; then
  echo "[Error] Split header review summary should hide trailing split words." >&2
  echo "$redacted_header_summary" >&2
  exit 1
fi
redacted_mixed_flag_header_cli="$(format_cli_equivalent add-header --req-resp response --header X-Token SECRET=top)"
if [[ "$redacted_mixed_flag_header_cli" == *"SECRET=top"* ]] ||
  [[ "$redacted_mixed_flag_header_cli" != *"--req-resp response"* ]] ||
  [[ "$redacted_mixed_flag_header_cli" != *"--header X-Token"* ]] ||
  [[ "$redacted_mixed_flag_header_cli" != *"[REDACTED]"* ]]; then
  echo "[Error] Mixed flag/positional header review output should redact the header value." >&2
  echo "$redacted_mixed_flag_header_cli" >&2
  exit 1
fi
redacted_mixed_flag_header_summary="$(_review_command_format_arg_summary add-header --req-resp response --header X-Token SECRET=top)"
if [[ "$redacted_mixed_flag_header_summary" == *"SECRET=top"* ]] ||
  [[ "$redacted_mixed_flag_header_summary" != *"[REDACTED]"* ]]; then
  echo "[Error] Mixed flag/positional header review summary should redact the header value." >&2
  echo "$redacted_mixed_flag_header_summary" >&2
  exit 1
fi
redacted_empty_flag_header_summary="$(_review_command_format_arg_summary add-header --req-resp response --header X-Token --value "" Bearer EMPTY_FLAG_HEADER_SECRET=top)"
if [[ "$redacted_empty_flag_header_summary" == *"EMPTY_FLAG_HEADER_SECRET=top"* ]] ||
  [[ "$redacted_empty_flag_header_summary" != *"[REDACTED]"* ]]; then
  echo "[Error] Empty flag-style header review summary should hide trailing split words." >&2
  echo "$redacted_empty_flag_header_summary" >&2
  exit 1
fi
redacted_variadic="$(format_cli_equivalent set-nginx-docker-opts --env SECRET=top --cpus 1)"
if [[ "$redacted_variadic" == *"SECRET=top"* ]] || [[ "$redacted_variadic" == *"--cpus"* ]] || [[ "$redacted_variadic" != "./dockistrate.sh set-nginx-docker-opts '[REDACTED]'" ]]; then
  echo "[Error] Variadic docker opts review output should redact all remaining words." >&2
  echo "$redacted_variadic" >&2
  exit 1
fi
redacted_empty_first_variadic="$(format_cli_equivalent set-nginx-docker-opts "" --env EMPTY_FIRST_SECRET=top --cpus 1)"
if [[ "$redacted_empty_first_variadic" == *"EMPTY_FIRST_SECRET=top"* ]] ||
  [[ "$redacted_empty_first_variadic" == *"--cpus"* ]] ||
  [[ "$redacted_empty_first_variadic" != "./dockistrate.sh set-nginx-docker-opts '[REDACTED]'" ]]; then
  echo "[Error] Variadic docker opts review output should redact trailing words after an empty first word." >&2
  echo "$redacted_empty_first_variadic" >&2
  exit 1
fi
clear_cli="$(format_cli_equivalent start-nginx --docker-opts "")"
if [[ "$clear_cli" == *"[REDACTED]"* ]] || [[ "$clear_cli" != "./dockistrate.sh start-nginx --docker-opts ''" ]]; then
  echo "[Error] Empty docker opts review output should preserve explicit clears." >&2
  echo "$clear_cli" >&2
  exit 1
fi
backend_clear_cli="$(format_cli_equivalent update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__)"
if [[ "$backend_clear_cli" == *"[REDACTED]"* ]] ||
  [[ "$backend_clear_cli" != "./dockistrate.sh update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__" ]]; then
  echo "[Error] Backend docker opts clear review output should preserve explicit clear sentinels." >&2
  echo "$backend_clear_cli" >&2
  exit 1
fi
backend_clear_summary="$(_review_command_format_arg_summary update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__)"
if [[ "$backend_clear_summary" == *"[REDACTED]"* ]] || [[ "$backend_clear_summary" != *"__DOCKER_OPTS_CLEAR__"* ]]; then
  echo "[Error] Backend docker opts clear review summary should preserve explicit clear sentinels." >&2
  echo "$backend_clear_summary" >&2
  exit 1
fi
hsts_off_cli="$(format_cli_equivalent set-hsts off)"
if [[ "$hsts_off_cli" == *"[REDACTED]"* ]] || [[ "$hsts_off_cli" != "./dockistrate.sh set-hsts off" ]]; then
  echo "[Error] HSTS off review output should preserve explicit clears." >&2
  echo "$hsts_off_cli" >&2
  exit 1
fi
hsts_off_cli="$(format_cli_equivalent set-hsts Off)"
if [[ "$hsts_off_cli" == *"[REDACTED]"* ]] || [[ "$hsts_off_cli" != "./dockistrate.sh set-hsts Off" ]]; then
  echo "[Error] HSTS Off review output should preserve explicit clears." >&2
  echo "$hsts_off_cli" >&2
  exit 1
fi
csp_off_summary="$(_review_command_format_arg_summary set-csp off)"
if [[ "$csp_off_summary" == *"[REDACTED]"* ]] || [[ "$csp_off_summary" != *"off"* ]]; then
  echo "[Error] CSP off review summary should preserve explicit clears." >&2
  echo "$csp_off_summary" >&2
  exit 1
fi
VISIBILITY_POLICY="full"

echo "[tests] review_command.sh: PASS"
