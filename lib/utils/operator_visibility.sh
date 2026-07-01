# shellcheck shell=bash

OPERATOR_VISIBILITY_REDACTED_VALUE="[REDACTED]"

function operator_visibility_policy() {
  local policy="${VISIBILITY_POLICY:-${DEFAULT_VISIBILITY_POLICY:-full}}"
  if declare -F is_valid_visibility_policy >/dev/null 2>&1 &&
    ! is_valid_visibility_policy "$policy"; then
    policy="${DEFAULT_VISIBILITY_POLICY:-full}"
  fi
  printf '%s\n' "$policy"
}

function operator_visibility_is_redacted() {
  [ "$(operator_visibility_policy)" = "redacted" ]
}

function operator_value_kind_is_redactable() {
  case "${1:-}" in
  docker_opts | header_value) return 0 ;;
  *) return 1 ;;
  esac
}

function operator_arg_is_redactable() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  *:docker_opts \
  | add-header:value | update-header:value \
  | add-backend-header:value | update-backend-header:value \
  | set-hsts:hsts_value | set-backend-hsts:backend_hsts_value \
  | set-csp:csp_value | set-backend-csp:backend_csp_value)
    return 0
    ;;
  esac
  return 1
}

function operator_arg_value_is_redactable() {
  local cmd="${1:-}" arg_name="${2:-}" value="${3:-}"
  local normalized_value=""

  [ -n "$value" ] || return 1
  operator_arg_is_redactable "$cmd" "$arg_name" || return 1
  normalized_value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"

  case "${cmd}:${arg_name}:${normalized_value}" in
  update-backend:docker_opts:__docker_opts_clear__ \
  | set-hsts:hsts_value:off \
  | set-backend-hsts:backend_hsts_value:off \
  | set-csp:csp_value:off \
  | set-backend-csp:backend_csp_value:off)
    return 1
    ;;
  esac

  return 0
}

function operator_value_for_display() {
  local kind="${1:-}" value="${2:-}"
  if [ -n "$value" ] &&
    operator_visibility_is_redacted &&
    operator_value_kind_is_redactable "$kind"; then
    printf '%s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
    return 0
  fi
  printf '%s' "$value"
}

function operator_arg_value_for_display() {
  local cmd="${1:-}" arg_name="${2:-}" value="${3:-}"
  if operator_visibility_is_redacted &&
    operator_arg_value_is_redactable "$cmd" "$arg_name" "$value"; then
    printf '%s' "$OPERATOR_VISIBILITY_REDACTED_VALUE"
    return 0
  fi
  printf '%s' "$value"
}
