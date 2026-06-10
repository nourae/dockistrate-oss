# shellcheck shell=bash
if ! declare -F __dockistrate_access_log_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/access_log.sh first.
  # shellcheck source=../access_log.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/access_log.sh"
fi

function add_log_field() {
  local field="${1:-}"
  local pos="${2:-}"
  [ -z "$field" ] && {
    echo "[Usage] add-log-field <field> [position]"
    exit 1
  }
  if ! is_valid_log_field "$field"; then
    echo "[Error] Invalid log field: field cannot contain single quotes, semicolons, or control characters" >&2
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_log_field"; then
    exit 1
  fi
  _access_log_load_fields || exit 1
  local count
  count=${#ACCESS_LOG_FIELDS[@]}

  local -a new_fields=()
  local i=0 inserted=false
  if [ -n "$pos" ]; then
    if ! [[ "$pos" =~ ^[0-9]+$ ]]; then
      echo "[Error] position must be numeric" >&2
      exit 1
    fi
    if [ "$pos" -lt 1 ]; then
      echo "[Error] position must be 1 or greater" >&2
      exit 1
    fi

    for ((i = 0; i < count; i++)); do
      if [ $((i + 1)) -eq "$pos" ]; then
        new_fields+=("$field")
        inserted=true
      fi
      new_fields+=("${ACCESS_LOG_FIELDS[$i]}")
    done
    if [ "$inserted" = false ]; then
      new_fields+=("$field")
    fi
  else
    new_fields=("${ACCESS_LOG_FIELDS[@]}" "$field")
  fi

  _access_log_write_fields "${new_fields[@]}" || exit 1
  echo "[Info] Added log field '$field'"
  create_backup "" "AddLogField"
  create_nginx_config
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
