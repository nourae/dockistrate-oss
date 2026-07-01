# shellcheck shell=bash

: "${CLI_PROMPT_CACHE_TOKEN:=0}"
CLI_DOCKER_NETWORKS_CACHE_TOKEN=""
CLI_DOCKER_NETWORKS_CACHE_VALUE=""

function _arg_choices_operator_value_for_display() {
  local kind="${1:-}" value="${2:-}"
  if declare -F operator_value_for_display >/dev/null 2>&1; then
    operator_value_for_display "$kind" "$value"
  else
    printf '%s' "$value"
  fi
}

function cli_prompt_cache_reset() {
  CLI_PROMPT_CACHE_TOKEN=$(( ${CLI_PROMPT_CACHE_TOKEN:-0} + 1 ))
}

function _cli_prompt_cached_docker_networks() {
  local cache_token="${CLI_PROMPT_CACHE_TOKEN:-0}"
  if [ "${CLI_DOCKER_NETWORKS_CACHE_TOKEN:-}" = "$cache_token" ]; then
    printf '%s' "${CLI_DOCKER_NETWORKS_CACHE_VALUE:-}"
    return 0
  fi

  local nets=""
  if command -v docker >/dev/null 2>&1; then
    nets="$(docker network ls --format '{{.Name}}' 2>/dev/null || true)"
  fi
  CLI_DOCKER_NETWORKS_CACHE_TOKEN="$cache_token"
  CLI_DOCKER_NETWORKS_CACHE_VALUE="$nets"
  printf '%s' "$nets"
}

function __arg_choices_docker_opts() {
  local cmd="$1"
  # For update-backend, present Keep current + Clear + Manual choices.
  if [ "$cmd" = "update-backend" ]; then
    local dom="${CURRENT_ARGS[0]:-}"
    if [ -n "$dom" ]; then
      local cur
      cur="$(get_backend_docker_opts "backend:${dom}")"
      if [ -n "$cur" ]; then
        echo "__DEFAULT__|Keep current: $(_arg_choices_operator_value_for_display docker_opts "$cur")"
        echo "__CLEAR__|Clear current options"
      else
        echo "__DEFAULT__|Keep current: (none)"
      fi
      echo "__MANUAL__|Enter manually..."
    fi
    return 0
  fi

  # For nginx docker options, present Keep current + Clear + Manual choices.
  if [ "$cmd" = "start-nginx" ] || [ "$cmd" = "set-nginx-docker-opts" ]; then
    if [ -n "${NGINX_DOCKER_OPTS:-}" ]; then
      echo "__DEFAULT__|Keep current: $(_arg_choices_operator_value_for_display docker_opts "$NGINX_DOCKER_OPTS")"
      echo "__CLEAR__|Clear current options"
    else
      echo "__DEFAULT__|Keep current: (none)"
    fi
    echo "__MANUAL__|Enter manually..."
  fi
}

function __arg_choices_network() {
  local cmd="$1"
  # List Docker networks and allow manual entry fallback
  local nets=""
  local dom="" cur_net=""
  # When updating a backend, set current network first for default selection
  if [ "$cmd" = "update-backend" ]; then
    dom="${CURRENT_ARGS[0]:-}"
    if [ -n "$dom" ]; then
      cur_net="$(get_backend_network "$dom")"
    fi
  fi
  nets="$(_cli_prompt_cached_docker_networks)"
  # ensure default exists in list
  if [ -n "$DEFAULT_NETWORK" ] && [ -n "$nets" ] && ! grep -qx "$DEFAULT_NETWORK" <<<"$nets"; then
    nets="$DEFAULT_NETWORK
$nets"
  fi
  if [ -n "$nets" ]; then
    # Reorder to put current network first when applicable
    if [ -n "$cur_net" ]; then
      {
        printf '%s\n' "$cur_net"
        printf '%s\n' "$nets" | awk 'NF' | sort -u | grep -vx "$cur_net"
      } | awk 'NF'
    else
      printf '%s\n' "$nets" | awk 'NF' | sort -u
    fi
    echo "__MANUAL__|Enter manually..."
  elif [ -n "$DEFAULT_NETWORK" ]; then
    echo "$DEFAULT_NETWORK"
    echo "__MANUAL__|Enter manually..."
  fi
}
