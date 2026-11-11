#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in utils/csv cli/common cli/arg_metadata cli/arg_option_hint cli/is_back_input cli/choose_option cli/mark_current_option cli/get_arg_spec cli/arg_choices_images cli/arg_choices_network_docker cli/prompt_args_handlers_defaults cli/prompt_args_handlers_postprocess cli/prompt_args_for_command; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
function fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function require_valid_var_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function cli_clear_screen() { :; }
function cli_render_header() { :; }
function cli_render_footer() { :; }
function cli_read_keypress() { printf -v "$1" '%s' ''; }
function cmd_requires_existing_backend() { return 1; }
function has_backends() { return 0; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function get_arg_choices() {
  if [ "$1" = update-backend ]; then
    case "$2" in
    domain) printf 'example.com|Example\n' ;;
    image) __arg_choices_image "$1" ;;
    container_port) __arg_choices_container_port "$1" ;;
    docker_opts) __arg_choices_docker_opts "$1" ;;
    network) __arg_choices_network "$1" ;;
    esac
    return 0
  fi
  case "$2" in
  domain) printf 'example.com|Example\n' ;;
  nginx_port) printf '443|443\n' ;;
  container_port) printf '80|80\n' ;;
  protocol) printf 'https|HTTPS\n' ;;
  cert_path) printf 'none|Self-signed certificate\n' ;;
  ws) printf 'yes|Yes\nno|No\n' ;;
  http3) printf 'on|On\noff|Off\n' ;;
  alt_svc) printf 'off|Off\nauto|Automatic\n' ;;
  fallback) printf 'first|misleading (current)\nsecond|second\n' ;;
  empty) printf 'first|first\nsecond|second\n' ;;
  literal) printf 'first|literal (current)\n%s|Literal value\n' "$LITERAL_VALUE" ;;
  unrelated) printf '__DEFAULT__|Unrelated sentinel\nsecond|Second\n' ;;
  esac
}
function review_command_before_run() {
  local review_index=""
  [ -z "${CLI_CHOICE_INITIAL_INDEX+x}" ] || fail 'Default selection leaked into the Run/Cancel review'
  choose_option review_index Review Run Cancel >/dev/null
  [ "$review_index" = 0 ] || fail 'Review inherited the previous prompt default'
}
INTERACTIVE=true
if ! prompt_args_for_command add-port >/dev/null; then fail 'Add-port prompting failed'; fi
expected=(example.com 443 80 https none no --http3 off --alt-svc auto)
[ "${#SELECTED_ARGS[@]}" = "${#expected[@]}" ] || fail 'Add-port argument count changed'
for index in "${!expected[@]}"; do
  [ "${SELECTED_ARGS[$index]}" = "${expected[$index]}" ] || fail "Enter chose incorrect default at argument $index"
done
[ -z "${CLI_CHOICE_INITIAL_INDEX+x}" ] || fail 'Generic prompt leaked initial selection to unrelated menus'

# A cached current image must not turn Enter into an explicit image update.
# Exercise the actual choice producers, including their Keep-current sentinels.
DEFAULT_NETWORK=dockistrate-net
function get_backend_image() { printf 'nginx:alpine\n'; }
function get_backend_port() { printf '80\n'; }
function get_backend_network() { printf 'dockistrate-net\n'; }
function get_backend_docker_opts() { printf '%s\n' '--cpus 2'; }
function _cli_prompt_cached_docker_images() { printf 'nginx:alpine|abc123|yesterday|\n'; }
function _cli_prompt_cached_docker_networks() { printf 'bridge\ndockistrate-net\n'; }
function docker() {
  [ "$1 $2" = 'image inspect' ] || fail 'Unexpected Docker operation during prompt'
  printf '{"80/tcp":{}}\n'
}
if ! prompt_args_for_command update-backend >/dev/null; then fail 'Update-backend prompting failed'; fi
[ "${#SELECTED_ARGS[@]}" -eq 5 ] || fail 'Update-backend argument shape changed'
[ -z "${SELECTED_ARGS[1]}" ] && [ -z "${SELECTED_ARGS[2]}" ] || fail 'Enter lost keep-current image/container-port intent'
[ "${SELECTED_ARGS[3]}" = '--cpus 2' ] && [ "${SELECTED_ARGS[4]}" = dockistrate-net ] || fail 'Existing options/network changed'

# Explicitly choosing the cached image must still request deliberate recreation.
IMAGE_CHOICE_SENT=false
function cli_read_keypress() {
  if [[ "${prompt:-}" == *'Container image'* ]] && [ "$IMAGE_CHOICE_SENT" = false ]; then
    IMAGE_CHOICE_SENT=true
    printf -v "$1" '%s' $'\e'
  else
    printf -v "$1" '%s' ''
  fi
}
function cli_read_escape_sequence() { printf -v "$1" '%s' '[B'; }
if ! prompt_args_for_command update-backend >/dev/null; then fail 'Explicit current-image selection failed'; fi
[ "$IMAGE_CHOICE_SENT" = true ] && [ "${SELECTED_ARGS[1]}" = nginx:alpine ] || fail 'Explicit image selection lost recreation intent'
function cli_read_keypress() { printf -v "$1" '%s' ''; }

# Underlying values decide selection; labels, shell-looking text and missing
# defaults must neither change choices nor execute input.
# shellcheck disable=SC2016
LITERAL_VALUE='$(false)'
function get_arg_spec() { printf 'fallback,missing;empty,;literal,%s;unrelated,second' "$LITERAL_VALUE"; }
if ! prompt_args_for_command defaults-test >/dev/null; then fail 'Default edge-case prompting failed'; fi
[ "${SELECTED_ARGS[0]}" = first ] && [ "${SELECTED_ARGS[1]}" = first ] || fail 'Unmatched/empty default changed the first-choice behavior'
[ "${SELECTED_ARGS[2]}" = "$LITERAL_VALUE" ] || fail 'Literal underlying default was not selected'
[ "${SELECTED_ARGS[3]}" = second ] || fail 'Unrelated sentinel overrode an ordinary value default'
printf '[tests] prompt_args_current_default_selection.sh: PASS\n'
