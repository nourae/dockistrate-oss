# shellcheck shell=bash

# A journal belongs to the outer content transaction. Each operation records
# intent before Docker changes, so recovery also covers an interrupted syscall.
function domain_config_runtime_enabled() {
  [ "${DOMAIN_CONFIG_ACTIVE:-false}" = true ] ||
    [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]
}

function _domain_runtime_journal_root() {
  printf '%s/runtime/transactions\n' "${STATE_DIR%/}"
}

function domain_config_runtime_recovery_pending() {
  local root="" journal=""
  root="$(_domain_runtime_journal_root)" || return 1
  for journal in "$root"/apply.* "$root"/preparing.*; do
    [ ! -d "$journal" ] || return 0
  done
  return 1
}

function domain_config_runtime_prepare() {
  [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 0
  transaction_is_active || return 1
  local root="" journal="" published="" target="" missing_target="" originally_missing=no number=0
  root="$(_domain_runtime_journal_root)" || return 1
  runtime_state_path_guard_if_declared "$root" "apply journal root" || return 1
  (umask 077; mkdir -p "$root") || return 1
  journal="$(mktemp -d "${root}/preparing.XXXXXXXX")" || return 1
  (umask 077; mkdir "$journal/operations") || return 1
  _domain_runtime_put "$journal/transaction.csv" journal_version 3 || return 1
  _domain_runtime_put "$journal/transaction.csv" state_schema_before "$(state_schema_read_marker_readonly)" || return 1
  _domain_runtime_put "$journal/transaction.csv" owner_pid "$$" || return 1
  _domain_runtime_put "$journal/transaction.csv" backup "${PRE_CHANGE_BACKUP:-}" || return 1
  printf '%s\n' 'position,path,originally_missing' >"$journal/targets.csv" || return 1
  for target in "${ROLLBACK_FILES[@]-}"; do
    [ -n "$target" ] || continue
    number=$((number + 1))
    originally_missing=no
    for missing_target in "${ROLLBACK_NEW_FILES[@]-}"; do
      [ "$missing_target" != "$target" ] || originally_missing=yes
    done
    csv_join_row "$number" "$target" "$originally_missing" >>"$journal/targets.csv" || return 1
  done
  _domain_runtime_put "$journal/transaction.csv" target_count "$number" || return 1
  _domain_runtime_put "$journal/transaction.csv" phase active || return 1
  published="${root}/apply.${journal##*.}"
  [ ! -e "$published" ] && mv "$journal" "$published" || return 1
  journal="$published"
  DOMAIN_CONFIG_RUNTIME_JOURNAL="$journal"
  DOMAIN_CONFIG_RUNTIME_OPERATION=0
  unset DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION
  rollback_pre_hook_add domain_config_runtime_rollback
  _backend_runtime_install_signal_traps
  domain_config_runtime_capture_proxy
}

function domain_config_runtime_capture_proxy() {
  local journal="${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" field="" value="" prepared=""
  [ -n "$journal" ] && [ -n "${NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED:-}" ] || return 0
  if [ -f "$journal/proxy.csv" ]; then return 0; fi
  prepared="$journal/proxy.preparing.csv"
  for field in NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED NGINX_RUNTIME_ROLLBACK_WAS_RUNNING \
    NGINX_RUNTIME_ROLLBACK_IMAGE NGINX_RUNTIME_ROLLBACK_BINDINGS NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED; do
    value=""
    if declare -p "$field" >/dev/null 2>&1; then value="${!field}"; fi
    _domain_runtime_put "$prepared" "$field" "$value" || return 1
  done
  mv "$prepared" "$journal/proxy.csv"
}

function domain_config_runtime_mark_proxy_changed() {
  local journal="${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}"
  [ -n "$journal" ] || return 0
  domain_config_runtime_capture_proxy || return 1
  [ -f "$journal/proxy.csv" ] || return 1
  _domain_runtime_put "$journal/proxy.csv" NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED true
}

function _domain_runtime_restore_proxy() {
  local journal="$1" field="" value=""
  [ -f "$journal/proxy.csv" ] || return 0
  for field in NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED NGINX_RUNTIME_ROLLBACK_WAS_RUNNING \
    NGINX_RUNTIME_ROLLBACK_IMAGE NGINX_RUNTIME_ROLLBACK_BINDINGS NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE; do
    value="$(_domain_runtime_get "$journal/proxy.csv" "$field")" || return 1
    printf -v "$field" '%s' "$value"
  done
  NGINX_RUNTIME_ROLLBACK_DEPTH=1
  NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED="$(_domain_runtime_get "$journal/proxy.csv" NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED true)" || return 1
  _nginx_runtime_rollback_if_needed || return 1
  _nginx_clear_runtime_rollback_state
}

function _domain_runtime_record() {
  local mode="${1:-}" domain="${2:-}" file="" key="" value=""
  shift 2 || return 1
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 0
  is_valid_domain "$domain" && [ "$domain" = "$(normalize_domain "$domain")" ] || return 1
  if [ -z "${DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION:-}" ]; then
    DOMAIN_CONFIG_RUNTIME_OPERATION=$((${DOMAIN_CONFIG_RUNTIME_OPERATION:-0} + 1))
    printf -v file '%s/operations/%08d.csv' "$DOMAIN_CONFIG_RUNTIME_JOURNAL" "$DOMAIN_CONFIG_RUNTIME_OPERATION"
    DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION="$file"
  fi
  file="$DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION"
  _domain_runtime_put "$file" mode "$mode" || return 1
  _domain_runtime_put "$file" domain "$domain" || return 1
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || return 1
    key="$1" value="$2"
    shift 2
    _domain_runtime_put "$file" "$key" "$value" || return 1
  done
  # Publish readiness last; an incomplete record precedes any Docker mutation.
  _domain_runtime_put "$file" ready yes
}

function _domain_runtime_finish_operation() {
  unset DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION
}

function _domain_runtime_restore_operation() {
  local file="$1" mode="" domain="" old_id="" old_token="" token="" name="" old_state=""
  local old_network="" new_network="" actual_name="" ip=""
  [ "$(_domain_runtime_get "$file" ready no)" = yes ] || return 0
  mode="$(_domain_runtime_get "$file" mode)" || return 1
  domain="$(_domain_runtime_get "$file" domain)" || return 1
  is_valid_domain "$domain" || return 1
  token="$(_domain_runtime_get "$file" new_token)" || return 1
  old_id="$(_domain_runtime_get "$file" old_id)" || return 1
  old_token="$(_domain_runtime_get "$file" old_token)" || return 1
  name="$(_domain_runtime_get "$file" name)" || return 1
  old_state="$(_domain_runtime_get "$file" old_state)" || return 1
  case "$mode" in
  add)
    _backend_launch_cleanup "$token" "$domain"
    ;;
  replace)
    _backend_launch_cleanup "$token" "$domain" || return 1
    if [ "$(_domain_runtime_get "$file" unmanaged false)" = true ]; then
      _backend_identity_inspect_unmanaged "$domain" "$old_id" || return 1
    else
      _backend_identity_inspect "$domain" "$old_id" "$old_token" || return 1
    fi
    actual_name="$(docker inspect -f '{{.Name}}' "$old_id")" || return 1
    [ "$actual_name" = "/$name" ] || docker rename "$old_id" "$name" || return 1
    if [ "$old_state" = running ]; then
      [ "$BACKEND_CONTAINER_STATUS" = running ] || docker start "$old_id" >/dev/null || return 1
    elif [ "$BACKEND_CONTAINER_STATUS" = running ]; then
      docker stop "$old_id" >/dev/null || return 1
    fi
    ;;
  network)
    _backend_identity_inspect "$domain" "$old_id" "$old_token" || return 1
    old_network="$(_domain_runtime_get "$file" old_network)" || return 1
    new_network="$(_domain_runtime_get "$file" new_network)" || return 1
    # Inspect membership, not IP: a stopped container can have an empty IP.
    if [ -n "$old_network" ] && [ "$(_domain_runtime_get "$file" old_network_existed true)" = true ] &&
      ! _domain_runtime_snapshot_has_network "$old_network"; then
      docker network connect "$old_network" "$old_id" || return 1
    fi
    if [ "$(_domain_runtime_get "$file" new_network_existed false)" != true ] &&
      _domain_runtime_snapshot_has_network "$new_network"; then
      docker network disconnect "$new_network" "$old_id" || return 1
    fi
    ;;
  state)
    _backend_identity_inspect "$domain" "$old_id" "$old_token" || return 1
    if [ "$old_state" = running ]; then
      [ "$BACKEND_CONTAINER_STATUS" = running ] || docker start "$old_id" >/dev/null || return 1
    elif [ "$BACKEND_CONTAINER_STATUS" = running ]; then
      docker stop "$old_id" >/dev/null || return 1
    fi
    ;;
  remove | certificate_remove | proxy_remove | shared_remove)
    # Removal is deferred until commit; there is no runtime mutation to undo.
    return 0
    ;;
  network_create)
    _domain_runtime_remove_created_network "$file"
    ;;
  *) return 1 ;;
  esac
}

function _domain_runtime_snapshot_has_network() {
  local network="${1:-}" row=""
  while IFS= read -r row || [ -n "$row" ]; do
    [ "${row%%|*}" != "$network" ] || return 0
  done <<<"${BACKEND_CONTAINER_NETWORKS:-}"
  return 1
}

function domain_config_runtime_rollback() {
  local journal="${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" file="" index=0 failed=false
  local -a operations=()
  [ -n "$journal" ] && [ -d "$journal" ] || return 0
  for file in "$journal/operations/"*.csv; do
    [ -f "$file" ] || continue
    operations+=("$file")
  done
  for ((index = ${#operations[@]} - 1; index >= 0; index--)); do
    [ "$(_domain_runtime_get "${operations[$index]}" mode)" != network_create ] || continue
    _domain_runtime_restore_operation "${operations[$index]}" || failed=true
  done
  if [ "$failed" = false ]; then
    if declare -F _domain_runtime_refresh_recovered_routes >/dev/null 2>&1; then
      _domain_runtime_refresh_recovered_routes "$journal" || failed=true
    fi
  fi
  if [ "$failed" = false ]; then
    _domain_runtime_restore_proxy "$journal" || failed=true
  fi
  # A failed proxy can still hold an endpoint on a newly created network. Its
  # old attachments must be restored before that empty network is removed.
  if [ "$failed" = false ]; then
    for ((index = ${#operations[@]} - 1; index >= 0; index--)); do
      [ "$(_domain_runtime_get "${operations[$index]}" mode)" = network_create ] || continue
      _domain_runtime_restore_operation "${operations[$index]}" || failed=true
    done
  fi
  if declare -F domain_config_source_rollback >/dev/null 2>&1; then
    domain_config_source_rollback "$journal" || failed=true
  fi
  # Shared header conflicts must retain both editor copies without preventing
  # restoration of the previous proxy from its generated configuration above.
  if declare -F domain_config_migration_files_rollback >/dev/null 2>&1; then
    domain_config_migration_files_rollback "$journal" headers || failed=true
  fi
  if declare -F _backup_rollback_deferred_domain_backup >/dev/null 2>&1; then
    _backup_rollback_deferred_domain_backup "$journal" || failed=true
  fi
  if [ "$failed" = true ]; then
    echo "[Error] Runtime recovery is incomplete; retained journal: $journal" >&2
    return 1
  fi
  _domain_runtime_put "$journal/transaction.csv" phase rolled_back || return 1
  safe_rm_rf "$journal" "$(_domain_runtime_journal_root)" || return 1
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION DOMAIN_CONFIG_RUNTIME_OPERATION
  if declare -F _backend_runtime_clear_signal_traps >/dev/null 2>&1; then _backend_runtime_clear_signal_traps; fi
}

# Called inside outer commit, before the lock is released. Cleanup is a separate
# post-commit operation: failure to remove an old container cannot undo commit.
function domain_config_runtime_commit() {
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 0
  if declare -F domain_config_migration_files_verify >/dev/null 2>&1; then
    domain_config_migration_files_verify "$DOMAIN_CONFIG_RUNTIME_JOURNAL" || return 1
  fi
  _domain_runtime_put "$DOMAIN_CONFIG_RUNTIME_JOURNAL/transaction.csv" phase committed
}

function domain_config_runtime_cleanup() {
  local journal="${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" file="" mode="" domain="" id="" token="" name="" failed=false
  [ -n "$journal" ] && [ -d "$journal" ] || return 0
  [ "$(_domain_runtime_get "$journal/transaction.csv" phase)" = committed ] || return 1
  if declare -F _backup_finish_deferred_domain_backup >/dev/null 2>&1; then
    _backup_finish_deferred_domain_backup "$journal" || failed=true
  fi
  for file in "$journal/operations/"*.csv; do
    [ -f "$file" ] || continue
    mode="$(_domain_runtime_get "$file" mode)" || return 1
    if [ "$mode" = proxy_remove ]; then
      _domain_runtime_delete_proxy "$file" || failed=true
      continue
    fi
    if [ "$mode" = shared_remove ]; then
      _domain_runtime_cleanup_shared "$(_domain_runtime_get "$file" scope)" || failed=true
      continue
    fi
    if [ "$mode" = certificate_remove ]; then
      domain="$(_domain_runtime_get "$file" domain)" || return 1
      id="$(_domain_runtime_get "$file" certificate_id)" || return 1
      _domain_cert_remove_external_material "$domain" "$id" "$(_domain_runtime_get "$file" legacy_source_ref)" "$file" || failed=true
      continue
    fi
    case "$mode" in replace | remove) ;; *) continue ;; esac
    domain="$(_domain_runtime_get "$file" domain)" || return 1
    id="$(_domain_runtime_get "$file" old_id)" || return 1
    token="$(_domain_runtime_get "$file" old_token)" || return 1
    if _backend_runtime_container_is_absent "$id"; then continue; fi
    if [ "$(_domain_runtime_get "$file" unmanaged false)" = true ]; then
      _backend_identity_inspect_unmanaged "$domain" "$id" || { failed=true; continue; }
    else
      _backend_identity_inspect "$domain" "$id" "$token" || { failed=true; continue; }
    fi
    if [ "$mode" = remove ]; then
      name="$(_domain_runtime_get "$file" name)" || return 1
      [ -n "$name" ] || name="backend-$(sanitize_domain_name "$domain")"
      if remove_container_and_anonymous_volumes "$id" >/dev/null; then
        printf "[Info] Removed backend container '%s'.\n" "$name"
        if declare -F log_msg >/dev/null 2>&1; then log_msg "Removed container $name."; fi
      else
        failed=true
      fi
    else
      remove_container_preserving_volumes "$id" >/dev/null || failed=true
    fi
  done
  if [ "$failed" = true ]; then
    echo "[Warn] Apply committed; deferred cleanup remains in $journal" >&2
  else
    safe_rm_rf "$journal" "$(_domain_runtime_journal_root)" || failed=true
  fi
  unset DOMAIN_CONFIG_RUNTIME_JOURNAL DOMAIN_CONFIG_RUNTIME_CURRENT_OPERATION DOMAIN_CONFIG_RUNTIME_OPERATION
  if declare -F _backend_runtime_clear_signal_traps >/dev/null 2>&1; then _backend_runtime_clear_signal_traps; fi
  [ "$failed" = false ]
}

function _domain_runtime_load_restored_settings() {
  # Source-only initialization can precede global settings. Keep that original
  # absence intact while still rejecting malformed or unsafe restored files.
  local DOMAIN_CONFIG_LEGACY_RECOVERY="${DOMAIN_CONFIG_LEGACY_RECOVERY:-false}" restored_schema=""
  if declare -F domain_config_migration_files_rollback >/dev/null 2>&1 && [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then
    domain_config_migration_files_rollback "$DOMAIN_CONFIG_RUNTIME_JOURNAL" settings || return 1
  fi
  restored_schema="$(state_schema_read_marker_readonly)" || return 1
  _domain_config_use_input_schema "$restored_schema" || return 1
  _global_settings_file_snapshot "$GLOBAL_SETTINGS_FILE" >/dev/null || return 1
  if [ -s "$GLOBAL_SETTINGS_FILE" ]; then load_config; else config_reset_defaults; fi
}

function _domain_runtime_recovery_target() {
  local file="$1" line="$2" position="$3" target="$4" missing="$5"
  : "$file" "$line"
  index=$((index + 1))
  [ "$position" = "$index" ] || return 1
  case "$missing" in yes | no) ;; *) return 1 ;; esac
  runtime_state_path_guard "$target" 'apply recovery target' || return 1
  targets+=("$target")
  if [ "$missing" = yes ]; then ROLLBACK_NEW_FILES+=("$target"); fi
}

function domain_config_runtime_recover() {
  local root="" journal="" phase="" pid="" backup="" count="" index=0 target="" failed=false header="" version="" previous="" current_schema=""
  local DOMAIN_CONFIG_LEGACY_RECOVERY=false DOMAIN_CONFIG_RECOVERING_JOURNAL=true DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  local STATE_SECURITY_RULES_HEADER="$STATE_SECURITY_RULES_HEADER" STATE_SECURITY_RULES_COLS="$STATE_SECURITY_RULES_COLS"
  local -a targets=() ROLLBACK_NEW_FILES=()
  root="$(_domain_runtime_journal_root)" || return 1
  [ -d "$root" ] || return 0
  [ "${TRANSACTION_LOCK_HELD:-false}" = true ] || {
    echo "[Error] Apply recovery requires the mutation lock." >&2
    return 1
  }
  # Preparation never mutates runtime. Only complete, atomically published
  # journals can authorize recovery after an interrupted process.
  for journal in "$root"/preparing.*; do
    [ -d "$journal" ] || continue
    safe_rm_rf "$journal" "$root" || return 1
  done
  for journal in "$root"/apply.*; do
    [ -d "$journal" ] || continue
    runtime_state_path_guard_if_declared "$journal" "apply recovery journal" || return 1
    [ -f "$journal/transaction.csv" ] || {
      echo "[Error] Incomplete apply journal: $journal" >&2
      return 1
    }
    IFS= read -r header <"$journal/transaction.csv" || return 1
    _domain_config_use_input_schema 5 || return 1
    if [ "${header%$'\r'}" = key,value ]; then
      # Schema-2 journals were unversioned. Their exact header selects the
      # compatibility codec; recovery completes them before any new migration.
      _domain_config_use_input_schema 2 || return 1
    else
      version="$(_domain_runtime_get "$journal/transaction.csv" journal_version)" || return 1
      [ "$version" = 3 ] || { _domain_config_error "Unsupported recovery journal version: $version"; return 1; }
      # Committed cleanup follows the committed layout, not the transaction's
      # previous layout (a committed migration may have changed the marker).
      current_schema="$(state_schema_read_marker_readonly)" || return 1
      _domain_config_use_input_schema "$current_schema" || return 1
    fi
    phase="$(_domain_runtime_get "$journal/transaction.csv" phase)" || return 1
    pid="$(_domain_runtime_get "$journal/transaction.csv" owner_pid)" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [ "$pid" != "$$" ] && _transaction_lock_pid_running "$pid"; then
      echo "[Error] Another apply still owns $journal" >&2
      return 1
    fi
    DOMAIN_CONFIG_RUNTIME_JOURNAL="$journal"
    case "$phase" in
    committed) domain_config_runtime_cleanup || return 1 ;;
    active)
      backup="$(_domain_runtime_get "$journal/transaction.csv" backup)" || return 1
      count="$(_domain_runtime_get "$journal/transaction.csv" target_count)" || return 1
      [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -le 100000 ] || return 1
      targets=(); ROLLBACK_NEW_FILES=()
      if [ "${header%$'\r'}" = key,value ]; then
        for ((index = 1; index <= count; index++)); do
          target="$(_domain_runtime_get "$journal/transaction.csv" "target_$index")" || return 1
          runtime_state_path_guard "$target" "apply recovery target" || return 1
          targets+=("$target")
          if [ "$(_domain_runtime_get "$journal/transaction.csv" "target_${index}_missing" no)" = yes ]; then
            ROLLBACK_NEW_FILES+=("$target")
          fi
        done
      else
        index=0
        [ -f "$journal/targets.csv" ] || return 1
        csv_read_records "$journal/targets.csv" 'position,path,originally_missing' _domain_runtime_recovery_target table || return 1
        [ "$index" -eq "$count" ] || return 1
        previous="$(_domain_runtime_get "$journal/transaction.csv" state_schema_before)" || return 1
        _domain_config_use_input_schema "$previous" || return 1
      fi
      restore_backup_archive "$backup" "${targets[@]+"${targets[@]}"}" || return 1
      _domain_runtime_load_restored_settings || return 1
      domain_config_runtime_rollback || return 1
      ;;
    rolled_back) safe_rm_rf "$journal" "$root" || return 1; unset DOMAIN_CONFIG_RUNTIME_JOURNAL ;;
    *) echo "[Error] Unknown apply recovery phase in $journal" >&2; return 1 ;;
    esac
  done
}
