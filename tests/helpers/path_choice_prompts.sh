# shellcheck shell=bash
# Globals are read by the sourced production prompts and their test callers.
# shellcheck disable=SC2034

# Exercise the production choice producer, decoders, generic collector and
# directive collector. Only terminal input and unrelated choices are scripted.
for path_choice_module in utils/csv utils/state_csv ports/common cli/common cli/arg_metadata cli/arg_option_hint cli/is_back_input cli/get_arg_spec cli/arg_choices_misc cli/prompt_args_handlers_defaults cli/prompt_args_handlers_postprocess cli/prompt_args_handlers_nginx_directives cli/prompt_args_for_command; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$path_choice_module.sh"
done
INTERACTIVE=true
PATH_CHOICE_INDEX=0
PATH_CHOICE_LABELS=()

function require_valid_var_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function cmd_requires_existing_backend() { return 1; }
function prompt_args_handle_headers() { return 2; }
function prompt_args_handle_security_specials() { return 2; }
function no_domain_overrides_message() { return 1; }
function no_header_overrides_message() { return 1; }
function no_port_tls_overrides_message() { return 1; }
function mark_current_option() { :; }
function review_command_before_run() { :; }

function get_arg_choices() {
  case "$2" in
  domain) printf 'example.com|Example backend\n' ;;
  nginx_port | port) printf '38080|HTTP listener\n' ;;
  path_prefix) __arg_choices_path_prefix "$1" ;;
  directive_scope) printf 'path|Path scope\n' ;;
  directive_name) printf 'proxy_read_timeout|Read timeout\n' ;;
  esac
}

function choose_option() {
  local choice_destination="$1" choice_prompt="$2"
  shift 2
  case "$choice_prompt" in
  *'Path prefix'* | path_prefix:)
    PATH_CHOICE_LABELS=("$@")
    printf -v "$choice_destination" '%s' "$PATH_CHOICE_INDEX"
    ;;
  *) printf -v "$choice_destination" '%s' 0 ;;
  esac
}

function read_with_editing() {
  local input_prompt="$1" input_destination="$2" input_value="${3:-}"
  [ "$input_prompt" != 'directive_value: ' ] || input_value=9s
  printf -v "$input_destination" '%s' "$input_value"
}

function collect_path_choice() {
  PATH_CHOICE_INDEX="$2"
  PATH_CHOICE_LABELS=()
  prompt_args_for_command "$1"
}
