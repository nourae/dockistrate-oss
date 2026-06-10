# shellcheck shell=bash
if ! declare -F __dockistrate_access_log_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/access_log.sh first.
  # shellcheck source=../access_log.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/access_log.sh"
fi

function remove_log_field() {
  local id="${1:-}"
  if ! [[ "$id" =~ ^[0-9]+$ ]]; then
    echo "[Usage] remove-log-field <id>"
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "remove_log_field_${id}"; then
    exit 1
  fi
  _access_log_load_fields || exit 1
  local field_count
  field_count=${#ACCESS_LOG_FIELDS[@]}
  if [ "$id" -lt 1 ] || [ "$id" -gt "$field_count" ]; then
    echo "[Error] log field id ${id} is out of range (1-${field_count})" >&2
    exit 1
  fi

  local -a new_fields=()
  local i=0
  for ((i = 0; i < field_count; i++)); do
    if [ $((i + 1)) -eq "$id" ]; then
      continue
    fi
    new_fields+=("${ACCESS_LOG_FIELDS[$i]}")
  done

  _access_log_write_fields "${new_fields[@]}" || exit 1
  echo "[Info] Removed log field $id"
  create_backup "" "RemoveLogField_${id}"
  create_nginx_config
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
