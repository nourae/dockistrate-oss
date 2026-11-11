# shellcheck shell=bash

if ! declare -F _finalize_global_settings_file >/dev/null 2>&1; then
  # shellcheck source=./settings_file.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/settings_file.sh"
fi

function _save_config_write_rows() {
  local key="" default_key="" index=0
  local -a headers=() values=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  csv_parse_line "$STATE_GLOBAL_SETTINGS_HEADER" || return 1
  headers=("${CSV_FIELDS[@]}")
  while IFS= read -r key; do
    default_key="DEFAULT_$key"
    # An unset optional runtime variable inherits its default; an explicitly
    # empty value remains empty (for example, a disabled client IP header).
    values+=("${!key-${!default_key}}")
  done < <(_global_settings_keys)
  if [ "${GLOBAL_SETTINGS_EXTENSION_FILE:-}" = "$GLOBAL_SETTINGS_FILE" ]; then
    for ((index = 0; index < ${#GLOBAL_SETTINGS_EXTENSION_HEADERS[@]}; index++)); do
      headers+=("${GLOBAL_SETTINGS_EXTENSION_HEADERS[index]}")
      values+=("${GLOBAL_SETTINGS_EXTENSION_VALUES[index]}")
    done
  fi
  csv_join_row "${headers[@]}" && csv_join_row "${values[@]}"
}

function _save_config_atomic_write() {
  local tmp_file=""
  local settings_dir="" staging_dir=""
  local settings_before="" temp_before="" directory_before=""

  settings_dir="$(dirname "$GLOBAL_SETTINGS_FILE" && printf '.')" || return 1
  settings_dir="${settings_dir%$'\n.'}"
  if declare -F runtime_state_path_guard >/dev/null 2>&1; then
    runtime_state_path_guard "$settings_dir" "global settings directory" || return 1
    runtime_state_path_guard "$GLOBAL_SETTINGS_FILE" "global settings file" || return 1
  fi
  mkdir -p "$settings_dir" || return 1
  if declare -F runtime_state_path_guard >/dev/null 2>&1; then
    runtime_state_path_guard "$settings_dir" "global settings directory" || return 1
    runtime_state_path_guard "$GLOBAL_SETTINGS_FILE" "global settings file" || return 1
  fi
  settings_before="$(_global_settings_file_snapshot "$GLOBAL_SETTINGS_FILE" || exit 1)" || return 1
  staging_dir="$(umask 077; mktemp -d "${settings_dir}/.global_settings.stage.XXXXXX" || exit 1)" || return 1
  # Five octal digits clear inherited directory set-ID bits on GNU chmod too.
  # Ownership remains inherited, preserving the group for a new settings file.
  if ! chmod 00700 "$staging_dir" ||
    ! directory_before="$(_global_settings_staging_directory_metadata "$staging_dir" || exit 1)"; then
    _global_settings_cleanup_staging "$staging_dir" "" || true
    return 1
  fi
  if ! make_temp_for_file tmp_file "${staging_dir}/settings"; then
    _global_settings_cleanup_staging "$staging_dir" "" || true
    return 1
  fi
  if ! _ensure_private_file_permissions "$tmp_file" ||
    ! temp_before="$(_global_settings_file_metadata "$tmp_file" || exit 1)"; then
    _global_settings_cleanup_staging "$staging_dir" "$tmp_file" || true
    return 1
  fi

  if ! _save_config_write_rows >"$tmp_file"; then
    _global_settings_cleanup_staging "$staging_dir" "$tmp_file" || true
    return 1
  fi

  if ! _finalize_global_settings_file "$GLOBAL_SETTINGS_FILE" "$tmp_file" "$settings_before" "$temp_before" "$directory_before"; then
    _global_settings_cleanup_staging "$staging_dir" "$tmp_file" || true
    return 1
  fi
  _global_settings_cleanup_staging "$staging_dir" ""
}

function save_config() {
  local started_txn=false

  if declare -F _config_begin_return_transaction_if_needed >/dev/null 2>&1; then
    _config_begin_return_transaction_if_needed started_txn "save_config" "$GLOBAL_SETTINGS_FILE" || return 1
  fi

  _save_config_atomic_write || {
    transaction_return_failure
    return 1
  }

  if [ "$started_txn" = true ] && declare -F _config_end_transaction_if_started >/dev/null 2>&1; then
    _config_end_transaction_if_started "$started_txn" || return 1
  fi
}
