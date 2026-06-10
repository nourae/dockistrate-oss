#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
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

echo "[tests] review_command.sh: PASS"
