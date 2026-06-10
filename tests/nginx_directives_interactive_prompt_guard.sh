#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/prompt_args_handlers_nginx_directives.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_nginx_directives.sh"

INTERACTIVE=true
PROMPT_ARGS_COLLECTED=()
CURRENT_ARGS=()
_CHOOSE_QUEUE=()
_READ_VALUE=""

fail() {
  echo "[Error] $1" >&2
  exit 1
}

require_valid_var_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

cli_choice_line_to_value_label() {
  local line="${1:-}" __value_var="${2:-}" __label_var="${3:-}"
  local value label
  if [[ "$line" == *"|"* ]]; then
    value="${line%%|*}"
    label="${line#*|}"
  else
    value="$line"
    label="$line"
  fi
  [ -n "$__value_var" ] && printf -v "$__value_var" '%s' "$value"
  [ -n "$__label_var" ] && printf -v "$__label_var" '%s' "$label"
}

choose_option() {
  local __resultvar="$1"
  require_valid_var_name "$__resultvar" || return 1
  if [ "${#_CHOOSE_QUEUE[@]}" -eq 0 ]; then
    fail "choose_option queue exhausted"
  fi
  printf -v "$__resultvar" '%s' "${_CHOOSE_QUEUE[0]}"
  _CHOOSE_QUEUE=("${_CHOOSE_QUEUE[@]:1}")
}

get_arg_choices() {
  local cmd="$1" arg="$2"
  case "$arg" in
  directive_scope)
    case "$cmd" in
    remove-all-nginx-directives | list-nginx-directives)
      printf '%s\n' "all|All scopes" "global|Global" "backend|Backend" "port|Port" "stream-global|Stream Global" "stream-backend|Stream Backend" "stream-port|Stream Port"
      ;;
    *)
      printf '%s\n' "global|Global" "backend|Backend" "port|Port" "stream-global|Stream Global" "stream-backend|Stream Backend" "stream-port|Stream Port"
      ;;
    esac
    ;;
  domain)
    printf '%s\n' "demo.test|demo.test"
    ;;
  port)
    printf '%s\n' "443|443 -> 8443 proto=https" "9000|9000 -> 9000 proto=tcp"
    ;;
  directive_name)
    printf '%s\n' "client_max_body_size|client_max_body_size" "proxy_read_timeout|proxy_read_timeout" "proxy_timeout|proxy_timeout"
    ;;
  esac
}

is_back_input() {
  local input="${1:-}"
  input="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
  [ "$input" = "back" ]
}

read_with_editing() {
  local _prompt="${1:-}" __out="${2:-}"
  printf -v "$__out" '%s' "$_READ_VALUE"
}

# Case 1: remove-all scope=all should not collect placeholder args.
_CHOOSE_QUEUE=(0)
PROMPT_ARGS_COLLECTED=()
if ! prompt_args_handle_nginx_directives remove-all-nginx-directives; then
  fail "remove-all-nginx-directives interactive handler should succeed"
fi
if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 0 ]; then
  fail "scope=all should collect zero args, got: ${PROMPT_ARGS_COLLECTED[*]}"
fi

# Case 2: set command must collect ordered args for port scope.
_CHOOSE_QUEUE=(2 0 0 0)
_READ_VALUE="16m"
PROMPT_ARGS_COLLECTED=()
if ! prompt_args_handle_nginx_directives set-nginx-directive; then
  fail "set-nginx-directive interactive handler should succeed"
fi

expected=("port" "demo.test" "443" "client_max_body_size" "16m")
if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne "${#expected[@]}" ]; then
  fail "set-nginx-directive collected unexpected arg count: ${#PROMPT_ARGS_COLLECTED[@]}"
fi

for idx in "${!expected[@]}"; do
  if [ "${PROMPT_ARGS_COLLECTED[$idx]}" != "${expected[$idx]}" ]; then
    fail "set-nginx-directive arg[$idx] expected '${expected[$idx]}', got '${PROMPT_ARGS_COLLECTED[$idx]}'"
  fi
done

# Case 3: set command must collect ordered args for stream-port scope.
_CHOOSE_QUEUE=(5 0 1 2)
_READ_VALUE="25s"
PROMPT_ARGS_COLLECTED=()
if ! prompt_args_handle_nginx_directives set-nginx-directive; then
  fail "set-nginx-directive stream-port flow should succeed"
fi

expected_stream=("stream-port" "demo.test" "9000" "proxy_timeout" "25s")
if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne "${#expected_stream[@]}" ]; then
  fail "set-nginx-directive stream-port collected unexpected arg count: ${#PROMPT_ARGS_COLLECTED[@]}"
fi

for idx in "${!expected_stream[@]}"; do
  if [ "${PROMPT_ARGS_COLLECTED[$idx]}" != "${expected_stream[$idx]}" ]; then
    fail "set-nginx-directive stream-port arg[$idx] expected '${expected_stream[$idx]}', got '${PROMPT_ARGS_COLLECTED[$idx]}'"
  fi
done

echo "[tests] nginx_directives_interactive_prompt_guard.sh: PASS"
