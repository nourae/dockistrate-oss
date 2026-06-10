#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/arg_option_hint.sh
source "$ROOT_DIR/lib/cli/arg_option_hint.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/is_back_input.sh
source "$ROOT_DIR/lib/cli/is_back_input.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/review_command.sh
source "$ROOT_DIR/lib/cli/review_command.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

INTERACTIVE=true
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()

READ_QUEUE=()
READ_CURSOR=0
CHOICE_QUEUE=()
CHOICE_CURSOR=0

function reset_prompt_review_test() {
  PROMPT_ARGS_COLLECTED=()
  SELECTED_ARGS=()
  SELECTED_CMD=""
  CURRENT_ARGS=()
  PROMPT_ARGS_CONTEXT=()
  READ_QUEUE=()
  CHOICE_QUEUE=()
  READ_CURSOR=0
  CHOICE_CURSOR=0
}

function get_arg_spec() {
  local cmd="${1:-}"
  case "$cmd" in
  mutating-test)
    printf '%s' 'first,;second,'
    ;;
  upgrade-preflight)
    printf '%s' 'target_tag,;require_backup,no'
    ;;
  status)
    printf '%s' ''
    ;;
  help-update)
    printf '%s' ''
    ;;
  *)
    return 1
    ;;
  esac
}

function get_arg_choices() { :; }
function mark_current_option() { :; }
function cmd_requires_existing_backend() { return 1; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function prompt_args_postprocess() { return 0; }
function prompt_args_compute_default() { printf '%s' "${3:-}"; }

function choose_option() {
  local __idx_var="${1:-}"
  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    echo "[Error] choose_option queue exhausted." >&2
    exit 1
  fi
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

function read_multiline_with_editing() {
  read_with_editing "$@"
}

reset_prompt_review_test
READ_QUEUE=("one" "two")
CHOICE_QUEUE=(0)
if ! prompt_args_for_command mutating-test >/dev/null; then
  echo "[Error] mutating command should run after review Run." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "mutating-test" ] || [ "${SELECTED_ARGS[*]}" != "one two" ]; then
  echo "[Error] mutating command selection mismatch after review." >&2
  exit 1
fi

reset_prompt_review_test
READ_QUEUE=("one" "two")
CHOICE_QUEUE=(1)
set +e
# shellcheck disable=SC2218
prompt_args_for_command mutating-test >/dev/null
status=$?
set -e
if [ "$status" -ne 2 ] || [ -n "${SELECTED_CMD:-}" ] || [ "${#SELECTED_ARGS[@]}" -ne 0 ]; then
  echo "[Error] review Edit should return status 2 and clear selection." >&2
  exit 1
fi

reset_prompt_review_test
if ! prompt_args_for_command status >/dev/null; then
  echo "[Error] read-only command should bypass review and select normally." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "status" ] || [ "$CHOICE_CURSOR" -ne 0 ]; then
  echo "[Error] read-only command should not ask for review." >&2
  exit 1
fi

reset_prompt_review_test
if ! prompt_args_for_command help-update >/dev/null; then
  echo "[Error] help-update should bypass review and select normally." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "help-update" ] || [ "$CHOICE_CURSOR" -ne 0 ]; then
  echo "[Error] help-update should not ask for review." >&2
  exit 1
fi

reset_prompt_review_test
READ_QUEUE=("" "no")
if ! prompt_args_for_command upgrade-preflight >/dev/null; then
  echo "[Error] upgrade-preflight should bypass review and select normally." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "upgrade-preflight" ] || [ "$CHOICE_CURSOR" -ne 0 ]; then
  echo "[Error] upgrade-preflight should not ask for review." >&2
  exit 1
fi

function prompt_args_handle_headers() {
  case "${1:-}" in
  set-hsts)
    SELECTED_CMD="set-hsts"
    SELECTED_ARGS=("max-age=60")
    return 0
    ;;
  esac
  return 2
}

reset_prompt_review_test
CHOICE_QUEUE=(0)
if ! prompt_args_for_command set-hsts >/dev/null; then
  echo "[Error] header special handler should run after review Run." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "set-hsts" ] || [ "${SELECTED_ARGS[*]}" != "max-age=60" ] || [ "$CHOICE_CURSOR" -ne 1 ]; then
  echo "[Error] header special handler did not pass through review." >&2
  exit 1
fi

function prompt_args_handle_nginx_directives() {
  case "${1:-}" in
  set-nginx-directive)
    PROMPT_ARGS_COLLECTED=("global" "client_max_body_size" "10m")
    return 0
    ;;
  clear-nginx-directives)
    PROMPT_ARGS_COLLECTED=()
    return 0
    ;;
  esac
  return 2
}

reset_prompt_review_test
CHOICE_QUEUE=(0)
if ! prompt_args_for_command set-nginx-directive >/dev/null; then
  echo "[Error] nginx directive special handler should run after review Run." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "set-nginx-directive" ] || [ "${SELECTED_ARGS[*]}" != "global client_max_body_size 10m" ] || [ "$CHOICE_CURSOR" -ne 1 ]; then
  echo "[Error] nginx directive special handler did not pass through review." >&2
  exit 1
fi

reset_prompt_review_test
CHOICE_QUEUE=(0)
if ! prompt_args_for_command clear-nginx-directives >/dev/null; then
  echo "[Error] no-arg special handler should run after review Run." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "clear-nginx-directives" ] || [ "${#SELECTED_ARGS[@]}" -ne 0 ] || [ "$CHOICE_CURSOR" -ne 1 ]; then
  echo "[Error] no-arg special handler did not pass through review safely." >&2
  exit 1
fi

function prompt_args_handle_security_specials() {
  case "${1:-}" in
  add-security-rule)
    PROMPT_ARGS_COLLECTED=("example.com" "1" "header" "User-Agent" "contains" "Bot")
    return 0
    ;;
  add-acl)
    PROMPT_ARGS_COLLECTED=("example.com" "deny" "192.0.2.10" "403")
    return 0
    ;;
  esac
  return 2
}

reset_prompt_review_test
if ! prompt_args_for_command add-security-rule >/dev/null; then
  echo "[Error] add-security-rule special handler should keep its own confirmation flow." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "add-security-rule" ] || [ "$CHOICE_CURSOR" -ne 0 ]; then
  echo "[Error] add-security-rule should not get a second review prompt." >&2
  exit 1
fi

reset_prompt_review_test
CHOICE_QUEUE=(0)
if ! prompt_args_for_command add-acl >/dev/null; then
  echo "[Error] security special handler should run after review Run." >&2
  exit 1
fi
if [ "$SELECTED_CMD" != "add-acl" ] || [ "${SELECTED_ARGS[*]}" != "example.com deny 192.0.2.10 403" ] || [ "$CHOICE_CURSOR" -ne 1 ]; then
  echo "[Error] security special handler did not pass through review." >&2
  exit 1
fi

# shellcheck source=../lib/cli/interactive_picker.sh
source "$ROOT_DIR/lib/cli/interactive_picker.sh"
PROMPT_CALLS=0
function prompt_args_for_command() {
  PROMPT_CALLS=$((PROMPT_CALLS + 1))
  if [ "$PROMPT_CALLS" -eq 1 ]; then
    return 2
  fi
  SELECTED_CMD="${1:-}"
  SELECTED_ARGS=("rerun")
  return 0
}
if ! interactive_picker_run_command_prompt mutating-test >/dev/null; then
  echo "[Error] picker should re-enter prompting after review Edit status." >&2
  exit 1
fi
if [ "$PROMPT_CALLS" -ne 2 ] || [ "$SELECTED_CMD" != "mutating-test" ] || [ "${SELECTED_ARGS[*]}" != "rerun" ]; then
  echo "[Error] picker did not re-enter the same command after review Edit." >&2
  exit 1
fi

echo "[tests] prompt_args_review_before_run.sh: PASS"
