#!/usr/bin/env bash

function _restore_trace_append() {
  [ -n "${TRACE_FILE:-}" ] || return 0
  printf '%s\n' "$1" >>"$TRACE_FILE"
}

function fix_permissions() {
  LAST_FIX_TARGET="${1:-}"
  _restore_trace_append "fix_permissions"
}

function update_nginx_config() {
  _restore_trace_append "update_nginx_config"
}

function normalize_nginx_image() {
  printf '%s\n' "${1:-}"
}

function find() {
  local start_path="${1:-}"
  case "${STUB_FIND_FAIL_MATCH:-}" in
  "")
    ;;
  *)
    case "$start_path" in
    ${STUB_FIND_FAIL_MATCH})
      return 1
      ;;
    esac
    ;;
  esac
  command find "$@"
}

function safe_rm_rf() {
  local target="${1:-}"
  shift || true
  _restore_trace_append "safe_rm_rf"
  case "${STUB_SAFE_RM_RF_FAIL_MATCH:-}" in
  "")
    ;;
  *)
    case "$target" in
    ${STUB_SAFE_RM_RF_FAIL_MATCH})
      STUB_SAFE_RM_RF_FAIL_MATCH=""
      return 1
      ;;
    esac
    ;;
  esac
  rm -rf "$target"
}

function remove_container_and_anonymous_volumes() {
  _restore_trace_append "remove_container_and_anonymous_volumes"
  STUB_CONTAINER_EXISTS="false"
  STUB_CONTAINER_RUNNING="false"
  STUB_PUBLISHED_BINDINGS=""
}

function container_published_port_bindings() {
  local binding=""
  for binding in ${STUB_PUBLISHED_BINDINGS:-}; do
    printf '%s\n' "$binding"
  done
}

function recreate_nginx_container() {
  local image="${1:-}" bindings=""
  RECREATE_CALL_COUNT=$((RECREATE_CALL_COUNT + 1))
  LAST_RECREATE_IMAGE="$image"
  if [ "$#" -ge 2 ]; then
    bindings="${2:-}"
  else
    bindings="${STUB_NEW_BINDINGS:-${STUB_PUBLISHED_BINDINGS:-}}"
  fi
  LAST_RECREATE_BINDINGS="$bindings"
  _restore_trace_append "recreate_nginx_container"
  _restore_trace_append "recreate_nginx_container:${RECREATE_CALL_COUNT}:${image}:${bindings}"
  if declare -F _nginx_mark_runtime_rollback_needed >/dev/null 2>&1; then
    _nginx_mark_runtime_rollback_needed
  fi
  STUB_CONTAINER_EXISTS="false"
  STUB_CONTAINER_RUNNING="false"
  STUB_PUBLISHED_BINDINGS=""
  if [ "${STUB_RECREATE_FAIL_ON_CALL:-0}" = "$RECREATE_CALL_COUNT" ]; then
    return 1
  fi
  STUB_CONTAINER_EXISTS="true"
  STUB_CONTAINER_RUNNING="true"
  STUB_PUBLISHED_BINDINGS="$bindings"
}

function check_config() {
  _restore_trace_append "check_config"
  [ "${STUB_CHECK_CONFIG_FAIL:-false}" != "true" ]
}

function container_running() {
  _restore_trace_append "container_running"
  [ "${STUB_CONTAINER_RUNNING:-false}" = "true" ]
}

function container_exists() {
  _restore_trace_append "container_exists"
  [ "${STUB_CONTAINER_EXISTS:-false}" = "true" ]
}

function docker() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
  inspect)
    if [ "${1:-}" = "-f" ] && [ -n "${2:-}" ]; then
      case "${2:-}" in
      *".Config.Labels"*)
        case "${2:-}" in
        *"com.dockistrate.managed"*) printf 'true\n' ;;
        *"com.dockistrate.role"*) printf 'proxy\n' ;;
        *"com.dockistrate.state-dir"*) printf '%s\n' "$STATE_DIR" ;;
        esac
        return 0
        ;;
      *".Mounts"*)
        cat <<EOF
${NGINX_CONFIG_DIR}|${NGINX_CONTAINER_CONF_ROOT}|false
${CERTS_DIR}|/etc/letsencrypt|false
${ACME_WEBROOT_DIR}|/var/www/certbot|false
EOF
        return 0
        ;;
      esac
    fi
    if [ "${1:-}" = "-f" ] && [ "${2:-}" = "{{.Config.Image}}" ]; then
      printf '%s\n' "${STUB_RUNNING_IMAGE:-$NGINX_IMAGE}"
      return 0
    fi
    return 0
    ;;
  stop)
    _restore_trace_append "docker_stop"
    STUB_CONTAINER_RUNNING="false"
    return 0
    ;;
  *)
    return 0
    ;;
  esac
}
