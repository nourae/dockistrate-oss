#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=lib/cli.sh
source "$ROOT_DIR/lib/cli.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_identity_picker.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
CONFIG_DIR="$FIXTURE"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 127.0.0.1:8000 dockistrate-net >>"$BACKEND_PORTS_FILE"
INTERACTIVE=true
TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
FULL_ID="$(printf '%064d' 1)"
READ_CURSOR=0
READ_QUEUE=()
function fail() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function get_backend_image() { printf '%s\n' "${PICKER_IMAGE:-}"; }
function get_backend_port() { printf '%s\n' "${PICKER_PORT:-}"; }
function get_backend_network() { printf 'dockistrate-net\n'; }
function get_backend_docker_opts() { printf '%s\n' "${PICKER_DOCKER_OPTS:-}"; }
function get_arg_choices() { :; }
function mark_current_option() { :; }
function choose_option() { printf -v "$1" '%s' 0; }
function read_with_editing() {
  local result_var="$2" result=""
  [ "$READ_CURSOR" -lt "${#READ_QUEUE[@]}" ] || fail 'unexpected extra prompt'
  result="${READ_QUEUE[$READ_CURSOR]}"
  READ_CURSOR=$((READ_CURSOR + 1))
  printf -v "$result_var" '%s' "$result"
}
function read_multiline_with_editing() { read_with_editing "$@"; }
function docker() { fail 'interactive collection must not discover or adopt a runtime container'; }

# Invalid empty image and abbreviated ID both keep the same field pending.
READ_QUEUE=(example.com '' __DEFAULT__ nginx:alpine '' '' dockistrate-net abc123 "$FULL_ID")
prompt_args_for_command update-backend >"$FIXTURE/output" 2>&1 || { cat "$FIXTURE/output" >&2; fail 'legacy update collection failed'; }
[ "${#SELECTED_ARGS[@]}" -eq 6 ] || fail 'legacy update lost the explicit recovery ID'
[ "${SELECTED_ARGS[1]}" = nginx:alpine ] && [ "${SELECTED_ARGS[5]}" = "$FULL_ID" ] || fail 'collector accepted unvalidated image or ID'
[ "$READ_CURSOR" -eq 9 ] || fail 'invalid legacy image or ID was not retried'
cli="$(_review_command_cli_equivalent update-backend "${SELECTED_ARGS[@]}")"
case "$cli" in *'--image nginx:alpine'*"--replace-unmanaged-container $FULL_ID"*) ;; *) fail 'review omitted explicit replacement flags' ;; esac

_backend_identity_store example.com "$FULL_ID" "$TOKEN"
READ_CURSOR=0
READ_QUEUE=(example.com '' '' '' dockistrate-net)
prompt_args_for_command update-backend >"$FIXTURE/output" 2>&1 || { cat "$FIXTURE/output" >&2; fail 'managed update collection failed'; }
[ "${#SELECTED_ARGS[@]}" -eq 5 ] || fail 'managed update changed its positional argument contract'
[ "$READ_CURSOR" -eq 5 ] || fail 'managed update incorrectly prompted for legacy recovery ID'

# Exercise the advertised options through the real choice parser, not blank
# text-input substitutes. Selecting a Keep current label returns __DEFAULT__.
# shellcheck source=lib/cli/get_arg_choices.sh
source "$ROOT_DIR/lib/cli/get_arg_choices.sh"
function _cli_prompt_cached_docker_images() { printf 'nginx:alpine|fixture-image|today|\n'; }
function _cli_prompt_cached_docker_networks() { printf 'dockistrate-net\n'; }
function docker() {
  if [ "${1:-}" = image ] && [ "${2:-}" = inspect ]; then
    printf '{}\n'
    return 0
  fi
  fail 'interactive choices must not discover or adopt a runtime container'
}
CHOICE_CURSOR=0
CHOICE_QUEUE=()
CHOICE_TRACE="$FIXTURE/choices.log"
function choose_option() {
  local result_var="$1" choice_wanted="" choice_label="" choice_index=0
  shift 2
  [ "$CHOICE_CURSOR" -lt "${#CHOICE_QUEUE[@]}" ] || fail 'unexpected extra option picker'
  choice_wanted="${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  for choice_label in "$@"; do
    if [ "$choice_label" = "$choice_wanted" ]; then
      printf '%s=%s\n' "${name:-review}" "${_vals[$choice_index]:-}" >>"$CHOICE_TRACE"
      printf -v "$result_var" '%s' "$choice_index"
      return 0
    fi
    choice_index=$((choice_index + 1))
  done
  fail "advertised choice missing: $choice_wanted"
}
PICKER_IMAGE=nginx:alpine
PICKER_PORT=8000
PICKER_DOCKER_OPTS='--label app=fixture'
READ_CURSOR=0
READ_QUEUE=()
CHOICE_QUEUE=(example.com 'Keep current: nginx:alpine' 'Keep current: 8000' 'Keep current: --label app=fixture' dockistrate-net Run)
: >"$CHOICE_TRACE"
prompt_args_for_command update-backend >"$FIXTURE/output" 2>&1 || { cat "$FIXTURE/output" >&2; fail 'managed Keep current collection failed'; }
[ "${#SELECTED_ARGS[@]}" -eq 5 ] || fail 'managed Keep current flow changed its argument contract'
[ -z "${SELECTED_ARGS[1]}" ] && [ -z "${SELECTED_ARGS[2]}" ] || fail 'managed Keep current sentinel reached backend image or port'
[ "${SELECTED_ARGS[3]}" = "$PICKER_DOCKER_OPTS" ] || fail 'managed Keep current changed Docker options'
[ "$READ_CURSOR" -eq 0 ] && [ "$CHOICE_CURSOR" -eq 6 ] || fail 'managed Keep current caused an extra prompt'
grep -Fxq 'image=__DEFAULT__' "$CHOICE_TRACE" || fail 'managed image test did not select the actual sentinel'
grep -Fxq 'container_port=__DEFAULT__' "$CHOICE_TRACE" || fail 'managed port test did not select the actual sentinel'
cli="$(_review_command_cli_equivalent update-backend "${SELECTED_ARGS[@]}")"
case "$cli" in *__DEFAULT__*) fail 'managed review exposed a Keep current placeholder' ;; esac

rm -f "$BACKEND_IDENTITY_FILE"
PICKER_IMAGE=''
CURRENT_ARGS=(example.com)
image_choices="$(get_arg_choices update-backend image)"
case "$image_choices" in *__DEFAULT__*) fail 'unmanaged recovery advertised keeping an unverified image' ;; esac
READ_CURSOR=0
READ_QUEUE=(nginx:alpine "$FULL_ID")
CHOICE_CURSOR=0
CHOICE_QUEUE=(example.com 'Enter manually...' 'Keep current: 8000' 'Clear current options' dockistrate-net 'Replace unmanaged container (enter full ID)' Run)
: >"$CHOICE_TRACE"
prompt_args_for_command update-backend >"$FIXTURE/output" 2>&1 || { cat "$FIXTURE/output" >&2; fail 'legacy Keep current port collection failed'; }
[ "${#SELECTED_ARGS[@]}" -eq 6 ] && [ "${SELECTED_ARGS[1]}" = nginx:alpine ] && [ "${SELECTED_ARGS[5]}" = "$FULL_ID" ] || fail 'legacy picker lost explicit image or full ID'
[ -z "${SELECTED_ARGS[2]}" ] || fail 'legacy Keep current sentinel reached backend port'
[ "${SELECTED_ARGS[3]}" = __DOCKER_OPTS_CLEAR__ ] || fail 'legacy picker lost explicit Docker options clear intent'
[ "$READ_CURSOR" -eq 2 ] && [ "$CHOICE_CURSOR" -eq 7 ] || fail 'legacy Keep current caused an extra prompt'
grep -Fxq 'container_port=__DEFAULT__' "$CHOICE_TRACE" || fail 'legacy port test did not select the actual sentinel'
cli="$(_review_command_cli_equivalent update-backend "${SELECTED_ARGS[@]}")"
case "$cli" in *'--image nginx:alpine'*"--docker-opts ''"*"--replace-unmanaged-container $FULL_ID"*) ;; *) fail 'legacy review changed explicit replacement or clear intent' ;; esac
case "$cli" in *__DEFAULT__*|*__DOCKER_OPTS_CLEAR__*|*--container-port*) fail 'legacy review exposed a picker placeholder or needless port override' ;; esac

# Network choices currently return the current name. Normalize a default marker
# at the command boundary consistently without consuming Docker's clear marker.
PROMPT_ARGS_COLLECTED=(example.com __DEFAULT__ __DEFAULT__ __DOCKER_OPTS_CLEAR__ __DEFAULT__ '')
prompt_args_postprocess update-backend
[ "${#PROMPT_ARGS_COLLECTED[@]}" -eq 5 ] || fail 'default normalization changed managed argument count'
[ -z "${PROMPT_ARGS_COLLECTED[1]}" ] && [ -z "${PROMPT_ARGS_COLLECTED[2]}" ] && [ -z "${PROMPT_ARGS_COLLECTED[4]}" ] || fail 'default marker survived update-backend postprocessing'
[ "${PROMPT_ARGS_COLLECTED[3]}" = __DOCKER_OPTS_CLEAR__ ] || fail 'postprocessing consumed Docker clear intent'
printf '[PASS] actual Keep current choices preserve managed and legacy update intent\n'

# shellcheck source=completion/dockistrate-completion.bash
source "$ROOT_DIR/completion/dockistrate-completion.bash"
function _get_comp_words_by_ref() {
  cur="${COMP_WORDS[$COMP_CWORD]}"
  prev="${COMP_WORDS[$((COMP_CWORD - 1))]}"
  cword="$COMP_CWORD"
  words=("${COMP_WORDS[@]}")
}
COMP_WORDS=(dockistrate.sh update-backend example.com --)
COMP_CWORD=3
COMPREPLY=()
_dockistrate_complete
case " ${COMPREPLY[*]-} " in *' --replace-unmanaged-container '*) ;; *) fail 'update completion omitted recovery flag' ;; esac
COMP_WORDS=(dockistrate.sh update-backend example.com --replace-unmanaged-container '')
COMP_CWORD=4
COMPREPLY=(stale)
_dockistrate_complete
[ "${#COMPREPLY[@]}" -eq 0 ] || fail 'completion suggested an unverified runtime ID'
printf '%s\n' 'Interactive backend identity recovery checks passed.'
