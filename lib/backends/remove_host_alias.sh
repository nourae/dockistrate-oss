# shellcheck shell=bash
function remove_host_alias() {
  local alias="${1:-}"
  if [ -z "$alias" ]; then
    echo "[Usage] remove-host-alias <alias>"
    exit 1
  fi

  alias="$(normalize_domain "$alias")"

  if ! alias_exists "$alias"; then
    echo "[Error] Alias '$alias' not found." >&2
    exit 1
  fi

  local aliases_file
  local target
  target="$(backend_for_alias "$alias")"
  aliases_file="$(backend_aliases_file)"
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_alias_${alias}"; then
    exit 1
  fi
  state_csv_delete_by_keys "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" 2 "alias" "$alias"
  echo "[Info] Removed host alias '${alias}'${target:+ (was -> ${target})}."
  log_msg "Removed host alias ${alias}"
  create_backup "" "RemoveAlias_${alias}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
