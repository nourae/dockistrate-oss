# shellcheck shell=bash

function _domain_runtime_ensure_network() {
  local domain="$1" network="$2" names="" name="" token="" state=""
  if [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then
    ensure_network_exists "$network"
    return $?
  fi
  names="$(docker network ls --format '{{.Name}}')" || return 1
  while IFS= read -r name; do [ "$name" != "$network" ] || return 0; done <<<"$names"
  token="$(_backend_launch_new_token)" || return 1
  state="$(_backend_identity_state_dir)" || return 1
  _domain_runtime_record network_create "$domain" network "$network" new_token "$token" state_dir "$state" || return 1
  docker network create --label com.dockistrate.managed=true \
    --label "com.dockistrate.state-dir=$state" --label "com.dockistrate.network-launch=$token" "$network" >/dev/null || return 1
  _domain_runtime_finish_operation
}

function _domain_runtime_remove_created_network() {
  local record="$1" network="" token="" state="" names="" name="" found=false verified="" template=""
  network="$(_domain_runtime_get "$record" network)" || return 1
  token="$(_domain_runtime_get "$record" new_token)" || return 1
  state="$(_domain_runtime_get "$record" state_dir)" || return 1
  [ -n "$network" ] && _backend_identity_valid_token "$token" || return 1
  names="$(docker network ls --format '{{.Name}}')" || return 1
  while IFS= read -r name; do [ "$name" != "$network" ] || found=true; done <<<"$names"
  [ "$found" = true ] || return 0
  template='{{if and (eq (index .Labels "com.dockistrate.managed") "true") (eq (index .Labels "com.dockistrate.state-dir") '"$(_backend_identity_go_literal "$state")"') (eq (index .Labels "com.dockistrate.network-launch") '"$(_backend_identity_go_literal "$token")"')}}verified{{end}}'
  verified="$(docker network inspect -f "$template" "$network")" || return 1
  [ "$verified" = verified ] || { echo "[Error] Refusing to remove a network whose apply ownership changed: $network" >&2; return 1; }
  docker network rm "$network" >/dev/null
}
