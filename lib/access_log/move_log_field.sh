# shellcheck shell=bash
if ! declare -F __dockistrate_access_log_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/access_log.sh first.
  # shellcheck source=../access_log.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/access_log.sh"
fi

function move_log_field() {
  local from="${1:-}" to="${2:-}"
  if ! [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]]; then
    echo "[Usage] move-log-field <from> <to>"
    exit 1
  fi
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "move_log_field_${from}_to_${to}"; then
    exit 1
  fi
  _access_log_load_fields || exit 1
  local count
  count=${#ACCESS_LOG_FIELDS[@]}
  if [ "$count" -eq 0 ]; then
    echo "[Error] No log fields configured." >&2
    exit 1
  fi
  if [ "$from" -lt 1 ] || [ "$from" -gt "$count" ] || [ "$to" -lt 1 ] || [ "$to" -gt "$count" ]; then
    echo "[Error] move range must be within 1-${count}" >&2
    exit 1
  fi

  local moving="${ACCESS_LOG_FIELDS[$((from - 1))]}"
  local -a without=()
  local i=0
  for ((i = 0; i < count; i++)); do
    if [ $((i + 1)) -eq "$from" ]; then
      continue
    fi
    without+=("${ACCESS_LOG_FIELDS[$i]}")
  done

  local insert_index=$((to - 1))
  local -a reordered=()
  local inserted=false
  for ((i = 0; i < ${#without[@]}; i++)); do
    if [ "$i" -eq "$insert_index" ]; then
      reordered+=("$moving")
      inserted=true
    fi
    reordered+=("${without[$i]}")
  done
  if [ "$inserted" = false ]; then
    reordered+=("$moving")
  fi

  _access_log_write_fields "${reordered[@]}" || exit 1
  echo "[Info] Moved log field $from -> $to"
  create_backup "" "MoveLogField_${from}_to_${to}"
  create_nginx_config
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
