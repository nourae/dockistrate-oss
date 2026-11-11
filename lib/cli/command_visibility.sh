# shellcheck shell=bash

# Display-only classification. Never pass these arrays to command execution:
# they may collapse an ambiguous or sensitive suffix to one placeholder.
CLI_VISIBILITY_DISPLAY_ARGS=()
CLI_VISIBILITY_HAS_SENSITIVE=false

function _cli_visibility_append_value() {
  local cmd="${1:-}" arg_name="${2:-}" value="${3:-}"
  if operator_arg_value_is_redactable "$cmd" "$arg_name" "$value"; then
    CLI_VISIBILITY_DISPLAY_ARGS+=("${OPERATOR_VISIBILITY_REDACTED_VALUE:-[REDACTED]}")
    CLI_VISIBILITY_HAS_SENSITIVE=true
  else
    CLI_VISIBILITY_DISPLAY_ARGS+=("$value")
  fi
}

function _cli_visibility_append_tail() {
  local cmd="${1:-}" arg_name="${2:-}" value="" sensitive=false
  shift 2 || return 0
  for value in "$@"; do
    if operator_arg_value_is_redactable "$cmd" "$arg_name" "$value"; then
      sensitive=true
      break
    fi
  done
  if [ "$sensitive" = true ]; then
    CLI_VISIBILITY_DISPLAY_ARGS+=("${OPERATOR_VISIBILITY_REDACTED_VALUE:-[REDACTED]}")
    CLI_VISIBILITY_HAS_SENSITIVE=true
  elif [ "$#" -gt 0 ]; then
    CLI_VISIBILITY_DISPLAY_ARGS+=("$@")
  fi
}

function _cli_visibility_option_takes_value() {
  case "${1:-}:${2:-}" in
  start-nginx:--nginx-image | start-nginx:--docker-opts \
  | add-backend:--listen | add-backend:--cert | add-backend:--ws \
  | add-backend:--docker-opts | add-backend:--network | add-backend:--expose \
  | update-backend:--image | update-backend:--container-port \
  | update-backend:--docker-opts | update-backend:--network \
  | update-backend:--replace-unmanaged-container)
    return 0
    ;;
  esac
  return 1
}

function _cli_visibility_option_is_boundary() {
  local cmd="${1:-}" option="${2:-}"
  # These parsers accept separate operands only. In particular,
  # --no-expose=anything and --network=anything are not safe boundaries.
  [ "$cmd:$option" = "add-backend:--no-expose" ] && return 0
  _cli_visibility_option_takes_value "$cmd" "$option"
}

function _cli_visibility_classify_options() {
  local cmd="${1:-}" option="" value=""
  shift || return 0
  while [ "$#" -gt 0 ]; do
    option="$1"
    case "$option" in
    --docker-opts)
      CLI_VISIBILITY_DISPLAY_ARGS+=("$option")
      shift
      [ "$#" -gt 0 ] || break
      value="$1"
      shift
      # A split options string must not leak through malformed trailing
      # operands, even if the first value is empty or a clear sentinel.
      if [ "$#" -gt 0 ] && ! _cli_visibility_option_is_boundary "$cmd" "$1"; then
        _cli_visibility_append_tail "$cmd" docker_opts "$value" "$@"
        return 0
      fi
      _cli_visibility_append_value "$cmd" docker_opts "$value"
      ;;
    --docker-opts=*)
      # This spelling is not accepted by execution, but a failed command
      # can still contain a secret and is audited before validation.
      value="${option#*=}"
      shift
      if [ "$#" -gt 0 ] && ! _cli_visibility_option_is_boundary "$cmd" "$1"; then
        CLI_VISIBILITY_DISPLAY_ARGS+=("--docker-opts=${OPERATOR_VISIBILITY_REDACTED_VALUE:-[REDACTED]}")
        CLI_VISIBILITY_HAS_SENSITIVE=true
        return 0
      fi
      if operator_arg_value_is_redactable "$cmd" docker_opts "$value"; then
        CLI_VISIBILITY_DISPLAY_ARGS+=("--docker-opts=${OPERATOR_VISIBILITY_REDACTED_VALUE:-[REDACTED]}")
        CLI_VISIBILITY_HAS_SENSITIVE=true
      else
        CLI_VISIBILITY_DISPLAY_ARGS+=("$option")
      fi
      ;;
    *)
      if [ "$cmd:$option" = "add-backend:--no-expose" ]; then
        CLI_VISIBILITY_DISPLAY_ARGS+=("$option")
        shift
      elif _cli_visibility_option_takes_value "$cmd" "$option"; then
        CLI_VISIBILITY_DISPLAY_ARGS+=("$option")
        shift
        if [ "$#" -gt 0 ]; then
          CLI_VISIBILITY_DISPLAY_ARGS+=("$1")
          shift
        fi
      else
        # Backend positional extras in CLI mode, unknown flags, and
        # unexpected operands are ambiguous. Hide this rejected suffix;
        # do not reinterpret it as a valid option or shift a field index.
        _cli_visibility_append_tail "$cmd" docker_opts "$@"
        return 0
      fi
      ;;
    esac
  done
}

function cli_classify_visibility_args() {
  local cmd="${1:-}" prefix_count=0 value_idx=-1 arg_name="" idx=0 scope="" option_start=0
  local args=()
  shift || true
  [ "$#" -eq 0 ] || args=("$@")
  CLI_VISIBILITY_DISPLAY_ARGS=()
  CLI_VISIBILITY_HAS_SENSITIVE=false

  if ! operator_visibility_is_redacted; then
    [ "$#" -eq 0 ] || CLI_VISIBILITY_DISPLAY_ARGS=("$@")
    return 0
  fi

  case "$cmd" in
  set-nginx-docker-opts)
    _cli_visibility_append_tail "$cmd" docker_opts "$@"
    return 0
    ;;
  add-header | update-header) value_idx=2; arg_name=value ;;
  add-backend-header | update-backend-header) value_idx=3; arg_name=value ;;
  set-hsts) value_idx=0; arg_name=hsts_value ;;
  set-csp) value_idx=0; arg_name=csp_value ;;
  set-backend-hsts) value_idx=1; arg_name=backend_hsts_value ;;
  set-backend-csp) value_idx=1; arg_name=backend_csp_value ;;
  set-nginx-directive | set-nginx-directive-raw)
    scope="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
    arg_name=directive_value
    case "$scope" in
    global | stream-global) value_idx=2 ;;
    backend | stream-backend) value_idx=3 ;;
    port | stream-port) value_idx=4 ;;
    path) value_idx=5 ;;
    *) value_idx=1 ;;
    esac
    ;;
  add-backend | update-backend)
    if [ "$cmd" = update-backend ] && [ "${INTERACTIVE:-false}" = true ] && [[ "${args[1]:-}" == --* ]]; then
      CLI_VISIBILITY_DISPLAY_ARGS+=("${args[0]}")
      _cli_visibility_classify_options "$cmd" "${args[@]:1}"
      return 0
    fi
    if [ "${INTERACTIVE:-false}" = true ]; then
      value_idx=7
      [ "$cmd" != "update-backend" ] || value_idx=3
      [ "${#args[@]}" -gt 0 ] || return 0
      option_start=${#args[@]}
      if [ "$cmd" = "add-backend" ]; then
        # add_backend consumes eight interactive extras when available,
        # otherwise six, then parses any remaining CLI options.
        if [ "${#args[@]}" -ge 12 ]; then
          option_start=12
        elif [ "${#args[@]}" -ge 10 ]; then
          option_start=10
        fi
      fi
      for idx in "${!args[@]}"; do
        if [ "$idx" -eq "$option_start" ]; then
          _cli_visibility_classify_options "$cmd" "${args[@]:$idx}"
          return 0
        fi
        case "${args[$idx]}" in
        --docker-opts | --docker-opts=*)
          # Saved or rejected commands may contain flag-form extras. A
          # secret-bearing spelling must not bypass positional detection.
          _cli_visibility_classify_options "$cmd" "${args[@]:$idx}"
          return 0
          ;;
        esac
        if [ "$idx" -eq "$value_idx" ]; then
          _cli_visibility_append_value "$cmd" docker_opts "${args[$idx]}"
        else
          CLI_VISIBILITY_DISPLAY_ARGS+=("${args[$idx]}")
        fi
      done
      return 0
    fi
    prefix_count=4
    [ "$cmd" != "update-backend" ] || prefix_count=1
    ;;
  start-nginx) prefix_count=0 ;;
  *)
    [ "$#" -eq 0 ] || CLI_VISIBILITY_DISPLAY_ARGS=("$@")
    return 0
    ;;
  esac

  if [ "$value_idx" -ge 0 ]; then
    # Fixed positions remain positions even if a value starts with '--'.
    # Header values and generic directives also hide split trailing words.
    while [ "$#" -gt 0 ] && [ "$idx" -lt "$value_idx" ]; do
      CLI_VISIBILITY_DISPLAY_ARGS+=("$1")
      shift
      idx=$((idx + 1))
    done
    _cli_visibility_append_tail "$cmd" "$arg_name" "$@"
    return 0
  fi

  while [ "$#" -gt 0 ] && [ "$idx" -lt "$prefix_count" ]; do
    CLI_VISIBILITY_DISPLAY_ARGS+=("$1")
    shift
    idx=$((idx + 1))
  done
  _cli_visibility_classify_options "$cmd" "$@"
}
