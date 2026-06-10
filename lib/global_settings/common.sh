# shellcheck shell=bash
#
# Shared constants for global settings handlers.

GLOBAL_SETTINGS_USAGE_PREFIX="[Usage]"
GLOBAL_SETTINGS_INFO_PREFIX="[Info]"
GLOBAL_SETTINGS_ERROR_PREFIX="[Error]"

function _global_settings_restore_security_update_flag() {
  local flag_name="${1:-}" previous_value="${2:-__dockistrate_unset__}"

  case "$flag_name" in
  DOCKISTRATE_FORCE_NGINX_RECREATE | DOCKISTRATE_SECURITY_NGINX_READY_CHECK) ;;
  *) return 1 ;;
  esac

  if [ "$previous_value" = "__dockistrate_unset__" ]; then
    unset "$flag_name"
  else
    printf -v "$flag_name" '%s' "$previous_value"
  fi
}

function _global_settings_update_nginx_config_for_security_change() {
  local previous_force="${DOCKISTRATE_FORCE_NGINX_RECREATE-__dockistrate_unset__}"
  local previous_ready="${DOCKISTRATE_SECURITY_NGINX_READY_CHECK-__dockistrate_unset__}"

  DOCKISTRATE_FORCE_NGINX_RECREATE=true
  if [ "${SKIP_UPDATE_NGINX_CONFIG:-}" = "true" ]; then
    DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE=true
  else
    DOCKISTRATE_SECURITY_NGINX_READY_CHECK=true
  fi

  if ! update_nginx_config; then
    _global_settings_restore_security_update_flag DOCKISTRATE_FORCE_NGINX_RECREATE "$previous_force"
    _global_settings_restore_security_update_flag DOCKISTRATE_SECURITY_NGINX_READY_CHECK "$previous_ready"
    return 1
  fi

  _global_settings_restore_security_update_flag DOCKISTRATE_FORCE_NGINX_RECREATE "$previous_force"
  _global_settings_restore_security_update_flag DOCKISTRATE_SECURITY_NGINX_READY_CHECK "$previous_ready"
}
