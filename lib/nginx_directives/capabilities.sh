# shellcheck shell=bash

function nginx_directive_module_flag_for_directive() {
  local directive="${1:-}"
  case "$directive" in
  ssl_preread)
    printf '%s\n' "--with-stream_ssl_preread_module"
    ;;
  *)
    return 1
    ;;
  esac
}

function _nginx_directive_capture_nginx_v_output() {
  local out_var="${1:-}" source_var="${2:-}"
  local output="" source=""

  require_valid_var_name "$out_var" || return 1
  require_valid_var_name "$source_var" || return 1

  if declare -F nginx_container_conflict_exists >/dev/null 2>&1 && nginx_container_conflict_exists; then
    output=""
  elif declare -F nginx_container_is_managed >/dev/null 2>&1 && nginx_container_is_managed && declare -F container_running >/dev/null 2>&1 && container_running "$NGINX_CONTAINER_NAME"; then
    output="$(docker exec "$NGINX_CONTAINER_NAME" nginx -V 2>&1 || true)"
    if [ -n "$output" ]; then
      source="running-container"
    fi
  fi

  if [ -z "$output" ]; then
    output="$(docker run --rm --entrypoint nginx "$NGINX_IMAGE" -V 2>&1 || true)"
    if [ -n "$output" ]; then
      source="image-preflight"
    fi
  fi

  printf -v "$out_var" '%s' "$output"
  printf -v "$source_var" '%s' "$source"
  return 0
}

function nginx_directive_preflight_required_module() {
  local scope="${1:-}" directive="${2:-}"
  local required_flag="" nginx_v_output="" source=""

  if ! nginx_directive_scope_is_stream "$scope"; then
    return 0
  fi

  required_flag="$(nginx_directive_module_flag_for_directive "$directive" 2>/dev/null || true)"
  [ -n "$required_flag" ] || return 0

  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    echo "[Warn] Skipping module capability check for '${directive}' because SKIP_DOCKER_CHECKS=true." >&2
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "[Warn] Docker is unavailable; skipping module capability check for '${directive}'." >&2
    return 0
  fi

  _nginx_directive_capture_nginx_v_output nginx_v_output source || true
  if [ -z "$nginx_v_output" ] || [[ "$nginx_v_output" != *"configure arguments:"* ]]; then
    echo "[Warn] Unable to determine Nginx compile flags; skipping module capability check for '${directive}'." >&2
    return 0
  fi

  if ! printf '%s' "$nginx_v_output" | grep -Fq -- "$required_flag"; then
    echo "[Error] Directive '${directive}' requires Nginx module flag '${required_flag}', but it is not present in ${source:-current runtime}. Use a compatible Nginx build or remove this directive." >&2
    return 1
  fi

  return 0
}
