# shellcheck shell=bash
if ! declare -F __dockistrate_access_log_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/access_log.sh first.
  # shellcheck source=../access_log.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/access_log.sh"
fi

function update_log_field() {
  local id="${1:-}"
  shift
  local field="$*"
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ -z "$field" ]; then
    echo "[Usage] update-log-field <id> <field>"
    exit 1
  fi
  if ! is_valid_log_field "$field"; then
    echo "[Error] Invalid log field: field cannot contain single quotes, semicolons, or control characters" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "update_log_field_${id}"; then
    exit 1
  fi
  _access_log_load_fields || exit 1
  local field_count
  field_count=${#ACCESS_LOG_FIELDS[@]}
  if [ "$id" -lt 1 ] || [ "$id" -gt "$field_count" ]; then
    echo "[Error] log field id ${id} is out of range (1-${field_count})" >&2
    exit 1
  fi
  ACCESS_LOG_FIELDS[$((id - 1))]="$field"
  _access_log_write_fields "${ACCESS_LOG_FIELDS[@]}" || exit 1
  echo "[Info] Updated log field $id to '$field'"
  create_backup "" "UpdateLogField_${id}"
  create_nginx_config
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
