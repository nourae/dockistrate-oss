#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/arg_option_hint.sh
source "$ROOT_DIR/lib/cli/arg_option_hint.sh"
# shellcheck source=../lib/cli/prompt_args_for_command.sh
source "$ROOT_DIR/lib/cli/prompt_args_for_command.sh"

INTERACTIVE=false
PROMPT_ARGS_COLLECTED=()
SELECTED_ARGS=()
SELECTED_CMD=""
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()

function get_arg_spec() {
  local cmd="${1:-}"
  [ "$cmd" = "metadata-test" ] || return 1
  printf '%s' 'docker_opts,'
}

function get_arg_choices() { :; }
function prompt_args_compute_default() { printf '%s' "${3:-}"; }
function prompt_args_postprocess() { return 0; }
function prompt_args_handle_security_specials() { return 2; }
function cmd_requires_existing_backend() { return 1; }
function is_back_input() { return 1; }

function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" default="${3:-}"
  printf -v "$__var" '%s' "$default"
}

CAPTURED_READ_PROMPT=""
function read() {
  local prompt="" out_var="" arg="" has_prompt=false
  local original_args=("$@")
  while [ "$#" -gt 0 ]; do
    arg="${1:-}"
    case "$arg" in
    -p)
      has_prompt=true
      shift
      prompt="${1:-}"
      ;;
    -*)
      ;;
    *)
      out_var="$arg"
      ;;
    esac
    shift || break
  done

  if [ "$has_prompt" != true ]; then
    # Non-prompt reads (e.g., `read -ra arr <<<"$str"` in cli_parse_arg_spec)
    # are safe to delegate to the builtin.
    builtin read "${original_args[@]}"
    return $?
  fi

  CAPTURED_READ_PROMPT="$prompt"
  if [ -n "$out_var" ]; then
    printf -v "$out_var" '%s' ""
  fi
  return 1
}

output_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_arg_metadata_prompt.XXXXXX")"
trap 'rm -f "$output_file"' EXIT

set +e
prompt_args_for_command metadata-test >"$output_file" 2>&1
status=$?
set -e
command_output="$(cat "$output_file")"
output="${CAPTURED_READ_PROMPT:-}"
printf '%s\n' "$output" >"$output_file"

if [ "$status" -ne 0 ]; then
  echo "[Error] prompt_args_for_command metadata-test failed unexpectedly." >&2
  echo "$command_output" >&2
  exit 1
fi

if [ -z "$output" ]; then
  echo "[Error] expected read_multiline_with_editing to pass prompt text to read -p." >&2
  echo "$command_output" >&2
  exit 1
fi

if ! grep -Fq "Extra Docker run options" "$output_file"; then
  echo "[Error] prompt should use friendly docker_opts label." >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -Fq "Optional Docker run flags." "$output_file"; then
  echo "[Error] prompt should include docker_opts help text." >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -Fq "Example: --cpus 1 --memory 256m" "$output_file"; then
  echo "[Error] prompt should include docker_opts example text." >&2
  echo "$output" >&2
  exit 1
fi

if ! grep -q "^Example: --cpus 1 --memory 256m" "$output_file"; then
  echo "[Error] docker_opts example should appear on its own line (no literal \\n sequences)." >&2
  echo "$output" >&2
  exit 1
fi

echo "[tests] prompt_args_arg_metadata_rendering.sh: PASS"
