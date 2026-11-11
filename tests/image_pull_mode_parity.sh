#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Exercise the actual digest-pinned defaults through metadata and both preset flows.
# shellcheck source=../lib/config/common.sh
source "$ROOT_DIR/lib/config/common.sh"
NGINX_PULL_MODE="never"
CERTBOT_PULL_MODE="if-missing"
CURRENT_ARGS=()
PROMPT_ARGS_CONTEXT=()
PROMPT_ARGS_COLLECTED=()
__dockistrate_completion_handlers=()

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/get_arg_spec.sh
source "$ROOT_DIR/lib/cli/get_arg_spec.sh"
# shellcheck source=../lib/cli/arg_choices_images.sh
source "$ROOT_DIR/lib/cli/arg_choices_images.sh"
# shellcheck source=../lib/cli/get_arg_choices.sh
source "$ROOT_DIR/lib/cli/get_arg_choices.sh"
# shellcheck source=../lib/cli/_validator_for.sh
source "$ROOT_DIR/lib/cli/_validator_for.sh"
# shellcheck source=../lib/cli/arg_metadata.sh
source "$ROOT_DIR/lib/cli/arg_metadata.sh"
# shellcheck source=../lib/cli/arg_option_hint.sh
source "$ROOT_DIR/lib/cli/arg_option_hint.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_defaults.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_defaults.sh"
# shellcheck source=../lib/cli/prompt_args_handlers_postprocess.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_postprocess.sh"
# shellcheck source=../completion/commands/_dockistrate_complete_option_values.sh
source "$ROOT_DIR/completion/commands/_dockistrate_complete_option_values.sh"

function assert_eq() {
  local expected="${1:-}" actual="${2:-}" label="${3:-value}"
  if [ "$expected" != "$actual" ]; then
    printf '[Error] %s: expected <%s>, got <%s>\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

function assert_array() {
  local label="$1"
  shift
  local expected=("$@") idx=0
  assert_eq "${#expected[@]}" "${#PROMPT_ARGS_COLLECTED[@]}" "$label length"
  for idx in "${!expected[@]}"; do
    assert_eq "${expected[$idx]}" "${PROMPT_ARGS_COLLECTED[$idx]}" "$label item $idx"
  done
}

function assert_spec() {
  local cmd="$1" image_arg="$2" expected_image="$3" expected_mode="$4"
  cli_parse_arg_spec "$(get_arg_spec "$cmd")"
  assert_eq "2" "${#CLI_SPEC_NAMES[@]}" "$cmd spec count"
  assert_eq "$image_arg" "${CLI_SPEC_NAMES[0]}" "$cmd image arg"
  assert_eq "$expected_image" "${CLI_SPEC_DEFAULTS[0]}" "$cmd image default"
  assert_eq "pull_mode" "${CLI_SPEC_NAMES[1]}" "$cmd pull-mode arg"
  assert_eq "$expected_mode" "${CLI_SPEC_DEFAULTS[1]}" "$cmd pull-mode default"
}

function assert_choice_order() {
  local cmd="$1" selected_image="$2" expected="$3" choices=""
  CURRENT_ARGS=("$selected_image")
  choices="$(get_arg_choices "$cmd" pull_mode)"
  assert_eq "$expected" "$(printf '%s\n' "$choices" | sed -n 's/|.*//p' | paste -sd' ' -)" "$cmd pull-mode choices"
}

function assert_completion() {
  local cmd="$1" partial="${2:-}" expected="$3"
  cur="$partial"
  prev="example/image:tag"
  cword=3
  words=(dockistrate.sh "$cmd" "example/image:tag")
  COMPREPLY=()
  if ! _dockistrate_complete_option_values "$cmd"; then
    echo "[Error] $cmd pull-mode completion was not handled." >&2
    exit 1
  fi
  assert_eq "$expected" "${COMPREPLY[*]-}" "$cmd pull-mode completion"
}

assert_spec "set-nginx-image" "nginx_image" "$NGINX_IMAGE" "$NGINX_PULL_MODE"
assert_spec "set-certbot-image" "certbot_image" "$CERTBOT_IMAGE" "$CERTBOT_PULL_MODE"
assert_eq "is_valid_pull_mode" "$(_validator_for set-nginx-image pull_mode)" "pull-mode validator"
assert_eq "Image pull mode" "$(arg_label pull_mode)" "pull-mode label"
assert_eq "always|if-missing|never" "$(arg_option_hint pull_mode)" "pull-mode hint"
assert_eq "if-missing" "$(arg_example set-nginx-image pull_mode)" "pull-mode example"

assert_choice_order "set-nginx-image" "__LATEST_IF_MISSING__" "if-missing always never"
assert_choice_order "set-nginx-image" "__LATEST_ALWAYS__" "always if-missing never"
assert_choice_order "set-nginx-image" "__PINNED_CURRENT__" "never always if-missing"
assert_choice_order "set-certbot-image" "registry.example/certbot:stable" "if-missing always never"

PROMPT_ARGS_CONTEXT=("__LATEST_IF_MISSING__")
assert_eq "if-missing" "$(prompt_args_compute_default set-nginx-image pull_mode never)" "latest-if-missing default"
PROMPT_ARGS_CONTEXT=("__LATEST_ALWAYS__")
assert_eq "always" "$(prompt_args_compute_default set-nginx-image pull_mode never)" "latest-always default"
PROMPT_ARGS_CONTEXT=("__PINNED_CURRENT__")
assert_eq "never" "$(prompt_args_compute_default set-nginx-image pull_mode if-missing)" "pinned-current default"

PROMPT_ARGS_COLLECTED=("registry.example/nginx:stable" "never")
prompt_args_postprocess set-nginx-image
assert_array "manual nginx image" "registry.example/nginx:stable" "never"

PROMPT_ARGS_COLLECTED=("registry.example/certbot:stable" "never")
prompt_args_postprocess set-certbot-image
assert_array "manual certbot image" "registry.example/certbot:stable" "never"

PROMPT_ARGS_COLLECTED=("__LATEST_IF_MISSING__")
prompt_args_postprocess set-nginx-image
assert_array "legacy nginx if-missing preset" "nginx:latest" "if-missing"
PROMPT_ARGS_COLLECTED=("__LATEST_ALWAYS__")
prompt_args_postprocess set-certbot-image
assert_array "legacy certbot always preset" "certbot/certbot:latest" "always"
PROMPT_ARGS_COLLECTED=("__PINNED_CURRENT__")
prompt_args_postprocess set-nginx-image
assert_array "legacy nginx current preset" "$NGINX_IMAGE" "$NGINX_PULL_MODE"
PROMPT_ARGS_COLLECTED=("__PINNED_CURRENT__")
prompt_args_postprocess set-certbot-image
assert_array "legacy certbot current preset" "$CERTBOT_IMAGE" "$CERTBOT_PULL_MODE"
PROMPT_ARGS_COLLECTED=("__LATEST_ALWAYS__" "never")
prompt_args_postprocess set-nginx-image
assert_array "explicit nginx preset override" "nginx:latest" "never"

if ! is_valid_pull_mode "always" || ! is_valid_pull_mode "if-missing" || ! is_valid_pull_mode "never"; then
  echo "[Error] A supported image pull mode was rejected." >&2
  exit 1
fi
if is_valid_pull_mode "sometimes"; then
  echo "[Error] Unsupported image pull mode was accepted." >&2
  exit 1
fi

assert_completion "set-nginx-image" "" "always if-missing never"
assert_completion "set-certbot-image" "i" "if-missing"

echo "[tests] image_pull_mode_parity.sh: PASS"
