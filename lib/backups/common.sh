# shellcheck shell=bash
#
# backups.sh - Backup and restore helpers

function transaction_is_active() {
  local depth="${TRANSACTION_DEPTH:-0}"
  if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if [ "$depth" -le 0 ]; then
    return 1
  fi
  if [ "${TRANSACTION_OWNER_PID:-}" != "$$" ]; then
    return 1
  fi
  if [ "${TRANSACTION_LOCK_HELD:-}" != "true" ]; then
    return 1
  fi
  [ -n "${ROLLBACK_DESC:-}" ]
}

function _transaction_uses_installed_traps() {
  [ "${TRANSACTION_MODE:-}" = "exit" ]
}

function _transaction_clear_installed_traps() {
  if _transaction_uses_installed_traps; then
    trap - ERR EXIT
  fi
}

function _config_begin_transaction_if_needed_mode() {
  local mode="${1:-exit}" __started_var="${2:-}" desc="${3:-}"
  require_valid_var_name "$__started_var" || return 1
  shift 3 || true

  local started="false"
  if ! transaction_is_active; then
    if [ "$mode" = "return" ]; then
      if ! begin_transaction_return "$desc" "$CONFIG_DIR" "$@"; then
        printf -v "$__started_var" '%s' "$started"
        return 1
      fi
    else
      if ! begin_transaction "$desc" "$CONFIG_DIR" "$@"; then
        printf -v "$__started_var" '%s' "$started"
        return 1
      fi
    fi
    started="true"
  fi

  printf -v "$__started_var" '%s' "$started"
}

function _config_begin_transaction_if_needed() {
  _config_begin_transaction_if_needed_mode exit "$@"
}

function _config_begin_return_transaction_if_needed() {
  _config_begin_transaction_if_needed_mode return "$@"
}

function _config_end_transaction_if_started() {
  local started="${1:-false}"
  if [ "$started" = "true" ]; then
    end_transaction_success
  fi
}

function _config_runtime_prep_lock_is_active() {
  if [ "${CONFIG_RUNTIME_PREP_LOCK_HELD:-}" != "true" ]; then
    return 1
  fi
  if [ "${CONFIG_RUNTIME_PREP_LOCK_OWNER_PID:-}" != "$$" ]; then
    return 1
  fi
  [ "${TRANSACTION_LOCK_HELD:-}" = "true" ]
}

function _config_write_lock_is_active() {
  transaction_is_active || _config_runtime_prep_lock_is_active
}

function _config_begin_runtime_prep_lock_if_needed() {
  local __started_var="${1:-}"
  require_valid_var_name "$__started_var" || return 1

  local started="false"
  if transaction_is_active || _config_runtime_prep_lock_is_active; then
    printf -v "$__started_var" '%s' "$started"
    return 0
  fi

  if ! acquire_transaction_lock; then
    printf -v "$__started_var" '%s' "$started"
    return 1
  fi

  CONFIG_RUNTIME_PREP_LOCK_HELD="true"
  CONFIG_RUNTIME_PREP_LOCK_OWNER_PID="$$"
  started="true"
  printf -v "$__started_var" '%s' "$started"
}

function _config_end_runtime_prep_lock_if_started() {
  local started="${1:-false}"
  if [ "$started" != "true" ]; then
    return 0
  fi

  if ! release_transaction_lock; then
    return 1
  fi

  unset CONFIG_RUNTIME_PREP_LOCK_HELD CONFIG_RUNTIME_PREP_LOCK_OWNER_PID
}

function transaction_return_failure() {
  if transaction_is_active && declare -F _rollback_handler_return >/dev/null 2>&1; then
    _rollback_handler_return
  fi
  return 1
}

function rollback_pre_hook_add() {
  local hook="${1:-}"
  [ -n "$hook" ] || return 0

  if [ -z "${ROLLBACK_PRE_HOOK:-}" ]; then
    ROLLBACK_PRE_HOOK="$hook"
    return 0
  fi

  case " ${ROLLBACK_PRE_HOOK} " in
  *" ${hook} "*) ;;
  *)
    ROLLBACK_PRE_HOOK="${ROLLBACK_PRE_HOOK} ${hook}"
    ;;
  esac
}

function rollback_pre_hook_remove() {
  local hook="${1:-}" existing="" current="" rebuilt=""
  [ -n "$hook" ] || return 0

  existing="${ROLLBACK_PRE_HOOK:-}"
  [ -n "$existing" ] || return 0

  for current in $existing; do
    [ "$current" = "$hook" ] && continue
    if [ -z "$rebuilt" ]; then
      rebuilt="$current"
    else
      rebuilt="${rebuilt} ${current}"
    fi
  done

  if [ -n "$rebuilt" ]; then
    ROLLBACK_PRE_HOOK="$rebuilt"
  else
    unset ROLLBACK_PRE_HOOK
  fi
}

function run_rollback_pre_hooks() {
  local hook="" failed=false nginx_hook=""
  for hook in ${ROLLBACK_PRE_HOOK:-}; do
    if [ "$hook" = _nginx_runtime_rollback_if_needed ]; then
      nginx_hook="$hook"
      continue
    fi
    if declare -F "$hook" >/dev/null 2>&1; then
      if ! "$hook"; then
        echo "[Error] Rollback hook failed: $hook" >&2
        failed=true
      fi
    else
      echo "[Error] Rollback hook is unavailable: $hook" >&2
      failed=true
    fi
  done
  # The proxy must see recovered backend identities/networks. Its snapshot
  # protection is registered at transaction start, before backend hooks exist.
  if [ -n "$nginx_hook" ]; then
    if ! declare -F "$nginx_hook" >/dev/null 2>&1 || ! "$nginx_hook"; then
      echo "[Error] Rollback hook failed: $nginx_hook" >&2
      failed=true
    fi
  fi
  [ "$failed" = false ]
}

function _nginx_runtime_rollback_capture_image() {
  local configured_image="${1:-${NGINX_IMAGE:-}}" running_image=""

  if [ -n "${NGINX_CONTAINER_NAME:-}" ] && nginx_container_is_managed; then
    running_image="$(docker inspect -f '{{.Config.Image}}' "$NGINX_CONTAINER_NAME" 2>/dev/null || true)"
  fi
  if [ -n "$running_image" ]; then
    configured_image="$running_image"
  fi
  if [ -n "$configured_image" ] && declare -F normalize_nginx_image >/dev/null 2>&1; then
    configured_image="$(normalize_nginx_image "$configured_image")"
  fi

  printf '%s\n' "$configured_image"
}

function _nginx_prepare_runtime_rollback() {
  local configured_image="${1:-${NGINX_IMAGE:-}}"
  local depth="${NGINX_RUNTIME_ROLLBACK_DEPTH:-0}"

  if ! [[ "$depth" =~ ^[0-9]+$ ]]; then
    depth=0
  fi

  if [ "$depth" -eq 0 ]; then
    local existed="false" was_running="false" bindings=""

    if [ -n "${NGINX_CONTAINER_NAME:-}" ] && nginx_container_is_managed; then
      existed="true"
      if container_running "$NGINX_CONTAINER_NAME"; then
        was_running="true"
      fi
      if declare -F container_published_port_bindings >/dev/null 2>&1; then
        bindings="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | xargs)"
      fi
    fi

    NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED="$existed"
    NGINX_RUNTIME_ROLLBACK_WAS_RUNNING="$was_running"
    NGINX_RUNTIME_ROLLBACK_IMAGE="$(_nginx_runtime_rollback_capture_image "$configured_image")"
    NGINX_RUNTIME_ROLLBACK_BINDINGS="$bindings"
    NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED="false"
    rollback_pre_hook_add "_nginx_runtime_rollback_if_needed"
  fi

  NGINX_RUNTIME_ROLLBACK_DEPTH=$((depth + 1))
  if declare -F domain_config_runtime_capture_proxy >/dev/null 2>&1; then
    domain_config_runtime_capture_proxy || return 1
  fi
}

function _nginx_mark_runtime_rollback_needed() {
  local depth="${NGINX_RUNTIME_ROLLBACK_DEPTH:-0}"
  if ! [[ "$depth" =~ ^[0-9]+$ ]] || [ "$depth" -le 0 ]; then
    return 0
  fi
  NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED="true"
  if declare -F domain_config_runtime_mark_proxy_changed >/dev/null 2>&1; then
    domain_config_runtime_mark_proxy_changed || return 1
  fi
}

function _nginx_clear_runtime_rollback_state() {
  rollback_pre_hook_remove "_nginx_runtime_rollback_if_needed"
  unset NGINX_RUNTIME_ROLLBACK_DEPTH
  unset NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED
  unset NGINX_RUNTIME_ROLLBACK_WAS_RUNNING
  unset NGINX_RUNTIME_ROLLBACK_IMAGE
  unset NGINX_RUNTIME_ROLLBACK_BINDINGS
  unset NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED
  unset NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE
}

function _nginx_release_runtime_rollback() {
  local depth="${NGINX_RUNTIME_ROLLBACK_DEPTH:-0}"

  if ! [[ "$depth" =~ ^[0-9]+$ ]] || [ "$depth" -le 0 ]; then
    _nginx_clear_runtime_rollback_state
    return 0
  fi

  if [ "$depth" -gt 1 ]; then
    NGINX_RUNTIME_ROLLBACK_DEPTH=$((depth - 1))
    return 0
  fi

  # A renderer may finish before its caller commits the enclosing transaction.
  # Keep the original runtime available if that later metadata commit fails.
  if transaction_is_active; then
    return 0
  fi

  _nginx_clear_runtime_rollback_state
}

function _nginx_runtime_rollback_if_needed() {
  local depth="${NGINX_RUNTIME_ROLLBACK_DEPTH:-0}"
  if ! [[ "$depth" =~ ^[0-9]+$ ]] || [ "$depth" -le 0 ]; then
    return 0
  fi
  local existed="${NGINX_RUNTIME_ROLLBACK_CONTAINER_EXISTED:-false}"
  local was_running="${NGINX_RUNTIME_ROLLBACK_WAS_RUNNING:-false}"
  local image="${NGINX_RUNTIME_ROLLBACK_IMAGE:-${NGINX_IMAGE:-}}"
  local bindings="${NGINX_RUNTIME_ROLLBACK_BINDINGS:-}"
  local projection="" apply_needed="${NGINX_RUNTIME_ROLLBACK_APPLY_NEEDED:-false}"
  if [ -n "${NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE:-}" ]; then
    # Recover before removing anything: issuer files may have changed outside
    # the transaction, so only its prevalidated snapshot is rollback authority.
    _nginx_recover_certificate_projection projection "$NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE" || return 1
    if ! _nginx_container_has_certificate_projection "$projection"; then
      apply_needed=true
    fi
  fi
  [ "$apply_needed" = true ] || return 0

  if [ -n "${NGINX_CONTAINER_NAME:-}" ] && nginx_container_is_managed; then
    remove_container_and_anonymous_volumes "$NGINX_CONTAINER_NAME" >/dev/null 2>&1 || true
  elif [ -n "${NGINX_CONTAINER_NAME:-}" ] && nginx_container_exists_any; then
    return 1
  fi

  if [ "$existed" != "true" ]; then
    return 0
  fi

  if [ -n "$projection" ]; then
    recreate_nginx_container "$image" "$bindings" "$projection" || return 1
  else
    recreate_nginx_container "$image" "$bindings" || return 1
  fi

  if [ "$was_running" != "true" ] && [ -n "${NGINX_CONTAINER_NAME:-}" ] && nginx_container_is_managed; then
    docker stop "$NGINX_CONTAINER_NAME" >/dev/null 2>&1 || return 1
    container_running "$NGINX_CONTAINER_NAME" && return 1
  fi

  if [ "$was_running" = "true" ] && [ -n "${NGINX_CONTAINER_NAME:-}" ] && ! container_running "$NGINX_CONTAINER_NAME"; then
    return 1
  fi
  if [ "$was_running" = true ] && [ -n "$projection" ] &&
    declare -F _nginx_wait_for_security_update_ready >/dev/null 2>&1; then
    _nginx_wait_for_security_update_ready || return 1
  fi

  return 0
}

function is_transaction_backup_archive() {
  local archive="${1:-}"
  [ -f "$archive" ] || return 1
  case "$archive" in
  *.tar.gz) ;;
  *) return 1 ;;
  esac
  local base
  base="$(basename "$archive")"
  case "$base" in
  *_pre_* | *_post_*) ;;
  *) return 1 ;;
  esac

  local first_entry="" top_level=""
  first_entry="$(LC_ALL=C tar -tzf "$archive" 2>/dev/null | head -n 1 || true)"
  [ -n "$first_entry" ] || return 1
  top_level="${first_entry%%/*}"
  case "$top_level" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]_*)
    return 1
    ;;
  esac
  return 0
}

function _sha256_digest_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 | awk '{print $NF}'
  else
    echo "[Error] Unable to find a SHA-256 checksum tool (sha256sum, shasum, or openssl)." >&2
    return 1
  fi
}

function _sha256_digest_file() {
  local file="${1:-}"
  [ -f "$file" ] || return 1

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    echo "[Error] Unable to find a SHA-256 checksum tool (sha256sum, shasum, or openssl)." >&2
    return 1
  fi
}

function _rollback_targets_signature() {
  local target normalized raw=""
  if [ "$#" -eq 0 ]; then
    printf 'none'
    return 0
  fi

  for target in "$@"; do
    normalized="${target%/}"
    [ -n "$normalized" ] || normalized="/"
    raw="${raw}${normalized}"$'\n'
  done

  printf '%s' "$raw" | LC_ALL=C sort | _sha256_digest_stdin
}

function _rollback_target_join_path() {
  local base="${1:-}" child="${2:-}"
  if [ "$base" = "/" ]; then
    printf '/%s\n' "$child"
  else
    printf '%s/%s\n' "$base" "$child"
  fi
}

function _rollback_target_churn_marker() {
  local path="${1:-}" nonce=""
  [ -n "$path" ] || return 1

  nonce="$(date '+%s%N' 2>/dev/null || true)"
  [ -n "$nonce" ] || nonce="$(date '+%s' 2>/dev/null || true)"
  [ -n "$nonce" ] || nonce="$$"

  printf 'C\t%s\t%s.%s.%s\n' "$path" "$nonce" "$$" "${RANDOM:-0}"
}

function _rollback_target_snapshot_metadata() {
  local path="${1:-}" metadata="" pattern=""
  [ -n "$path" ] || return 1
  # Reads can change atime; ctime and ownership are not restored. Include the
  # permissions and full mtime that archive extraction/replay can preserve.
  # BSD %p retains special permission bits; %.9Fm emits exact seconds/nanoseconds.
  if metadata="$(LC_ALL=C TZ=UTC0 stat -c '%a|%y' "$path" 2>/dev/null)"; then
    pattern='^[0-7]+[|]-?[0-9]+-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)? [+-][0-9][0-9][0-9][0-9]$'
  elif metadata="$(LC_ALL=C TZ=UTC0 stat -f '%p|%.9Fm' "$path" 2>/dev/null)"; then
    pattern='^[0-7]+[|]-?[0-9]+[.][0-9]{9}$'
  else
    return 1
  fi
  [[ "$metadata" =~ $pattern ]] || return 1
  printf '%s\n' "$metadata"
}

function _rollback_target_state_entry_line() {
  local path="${1:-}" entry_checksum="" link_target="" metadata=""
  [ -n "$path" ] || return 1

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    printf 'M\t%s\n' "$path"
    return 0
  fi

  if [ -L "$path" ]; then
    link_target="$(readlink -n "$path" 2>/dev/null && printf '.')" || return 1
    link_target="${link_target%.}"
    metadata="$(_rollback_target_snapshot_metadata "$path")" || return 1
    printf 'L\t%s\t%s\t%s\n' "$path" "$link_target" "$metadata"
    return 0
  fi

  if [ -f "$path" ]; then
    if ! entry_checksum="$(_sha256_digest_file "$path" 2>/dev/null)"; then
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        printf 'M\t%s\n' "$path"
        return 0
      fi
      return 1
    fi
    if ! metadata="$(_rollback_target_snapshot_metadata "$path")"; then
      if [ ! -e "$path" ] && [ ! -L "$path" ]; then
        printf 'M\t%s\n' "$path"
        return 0
      fi
      return 1
    fi
    printf 'F\t%s\t%s\t%s\n' "$path" "$entry_checksum" "$metadata"
    return 0
  fi

  if [ -d "$path" ]; then
    metadata="$(_rollback_target_snapshot_metadata "$path")" || return 1
    printf 'D\t%s\t%s\n' "$path" "$metadata"
    return 0
  fi

  printf 'O\t%s\n' "$path"
}

function _rollback_target_state_lines() {
  local target="${1:-}" normalized="" listing="" relative_path="" current_path=""
  local listing_status=0 stderr_file="" find_errors=""
  [ -n "$target" ] || return 1

  normalized="${target%/}"
  [ -n "$normalized" ] || normalized="/"

  if [ -d "$normalized" ] && [ ! -L "$normalized" ]; then
    stderr_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_find_stderr.XXXXXX")" || return 1
    listing="$(cd "$normalized" && LC_ALL=C find . -mindepth 1 -print 2>"$stderr_file" | LC_ALL=C sed 's#^\./##' | LC_ALL=C sort)" || listing_status=$?
    find_errors="$(cat "$stderr_file" 2>/dev/null || true)"
    rm -f "$stderr_file"

    if [ "$listing_status" -ne 0 ]; then
      if [ ! -e "$normalized" ] && [ ! -L "$normalized" ]; then
        printf 'M\t%s\n' "$normalized"
        return 0
      fi
      if [ -z "$find_errors" ]; then
        return 1
      fi
      if printf '%s\n' "$find_errors" | LC_ALL=C grep -Fv 'No such file or directory' | LC_ALL=C grep -q '[^[:space:]]'; then
        return 1
      fi
      _rollback_target_churn_marker "$normalized"
      return 0
    fi

    _rollback_target_state_entry_line "$normalized" || return 1
    [ -n "$listing" ] || return 0
    while IFS= read -r relative_path; do
      [ -n "$relative_path" ] || continue
      current_path="$(_rollback_target_join_path "$normalized" "$relative_path")"
      if ! _rollback_target_state_entry_line "$current_path"; then
        return 1
      fi
    done <<<"$listing"
    return 0
  fi

  _rollback_target_state_entry_line "$normalized"
}

function _rollback_targets_state_signature() {
  local target raw="" target_lines=""
  if [ "$#" -eq 0 ]; then
    printf 'none'
    return 0
  fi

  for target in "$@"; do
    if ! target_lines="$(_rollback_target_state_lines "$target")"; then
      return 1
    fi
    raw="${raw}${target_lines}"$'\n'
  done

  printf '%s' "$raw" | LC_ALL=C sort | _sha256_digest_stdin
}

function _sanitize_backup_label() {
  local raw="${1:-}"
  local sanitized=""
  sanitized="$(printf '%s' "$raw" | LC_ALL=C sed 's/[[:space:]]/_/g; s/[^A-Za-z0-9._-]/_/g')"
  while [[ "$sanitized" == *".."* ]]; do
    sanitized="${sanitized//../_}"
  done
  printf '%s' "$sanitized"
}

function is_valid_backup_name() {
  local name="${1:-}"
  [ -n "$name" ] || return 1
  case "$name" in
  *"/"* | *"\\"* | *".."*)
    return 1
    ;;
  esac
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  return 0
}

function require_valid_backup_name() {
  local name="${1:-}"
  if ! is_valid_backup_name "$name"; then
    echo "[Error] Invalid backup name: $name" >&2
    return 1
  fi
}

function _ensure_backup_dir_secure() {
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
  fi
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$BACKUP_DIR" "backup directory" || return 1
  fi
  chmod 700 "$BACKUP_DIR" 2>/dev/null || true
}

function _backup_resolve_path_within_root() {
  local __out_var="${1:-}" raw_path="${2:-}"
  require_valid_var_name "$__out_var" || return 1
  [ -n "$raw_path" ] || return 1

  local root_norm path_norm
  if ! root_norm="$(_realpath_portable "$BACKUP_DIR" 2>/dev/null && printf '.')"; then
    echo "[Error] Unable to resolve backup root: $BACKUP_DIR" >&2
    return 1
  fi
  root_norm="${root_norm%.}"
  if ! path_norm="$(_normalize_delete_target_path "$raw_path" 2>/dev/null && printf '.')"; then
    echo "[Error] Invalid backup path: $raw_path" >&2
    return 1
  fi
  path_norm="${path_norm%.}"

  case "$path_norm" in
  "$root_norm" | "$root_norm"/*) ;;
  *)
    echo "[Error] Backup path '$raw_path' resolves outside backup root '$BACKUP_DIR'." >&2
    return 1
    ;;
  esac

  printf -v "$__out_var" '%s' "$path_norm"
}

function _backup_safe_rm_rf() {
  local target="${1:-}"
  [ -n "$target" ] || return 1
  safe_rm_rf "$target" "$BACKUP_DIR"
}

function _backup_safe_rm_f() {
  local target="${1:-}"
  [ -n "$target" ] || return 1
  safe_rm_f "$target" "$BACKUP_DIR"
}

function _backup_ensure_runtime_defaults() {
  local state_root="${STATE_DIR:-}"
  if [ -z "$state_root" ]; then
    state_root="${BASE_DIR:-$PWD}/state"
  fi
  if [ -z "${BACKUP_DIR:-}" ]; then
    BACKUP_DIR="${state_root}/backups"
  fi
  if [ -z "${TMP_DIR:-}" ]; then
    TMP_DIR="${state_root}/tmp"
  fi
}

function _backup_archive_checksum_file() {
  local archive="${1:-}"
  [ -n "$archive" ] || return 1
  printf '%s.sha256\n' "$archive"
}

function _write_backup_archive_checksum() {
  local archive="${1:-}" checksum_file="" digest="" tmp_file=""
  [ -f "$archive" ] || return 1
  checksum_file="$(_backup_archive_checksum_file "$archive")" || return 1
  digest="$(_sha256_digest_file "$archive")" || return 1
  make_temp_for_file tmp_file "$checksum_file" || return 1
  printf '%s  %s\n' "$digest" "$(basename "$archive")" >"$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }
  finalize_temp_file_with_mode "$checksum_file" "$tmp_file" 600 || {
    rm -f "$tmp_file"
    return 1
  }
}

function _verify_backup_archive_checksum_if_present() {
  local archive="${1:-}" digest_archive="${2:-${1:-}}"
  local checksum_file="" line="" expected="" checksum_name="" extra="" actual=""
  [ -n "$archive" ] || return 1
  [ -f "$digest_archive" ] || return 1
  checksum_file="$(_backup_archive_checksum_file "$archive")" || return 1
  if [ ! -f "$checksum_file" ]; then
    echo "[Warn] No checksum sidecar found for backup archive: $archive" >&2
    return 0
  fi

  IFS= read -r line <"$checksum_file" || line=""
  IFS=' ' read -r expected checksum_name extra <<<"$line"
  if [ -n "${extra:-}" ]; then
    echo "[Error] Invalid checksum sidecar for backup archive: $checksum_file" >&2
    return 1
  fi
  if ! [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]]; then
    echo "[Error] Invalid checksum sidecar for backup archive: $checksum_file" >&2
    return 1
  fi
  if [ -n "$checksum_name" ] && [ "$checksum_name" != "$(basename "$archive")" ]; then
    echo "[Error] Checksum sidecar ${checksum_file} references '${checksum_name}', expected '$(basename "$archive")'." >&2
    return 1
  fi
  actual="$(_sha256_digest_file "$digest_archive")" || return 1
  if [ "$actual" != "$expected" ]; then
    echo "[Error] Backup archive checksum mismatch: $archive" >&2
    return 1
  fi
}

function _backup_remove_private_restore_dir() {
  local restore_dir="${1:-}" tmp_root=""
  _backup_ensure_runtime_defaults
  [ -n "$restore_dir" ] || return 0
  tmp_root="${TMP_DIR%/}"
  case "$restore_dir" in
  "$tmp_root"/restore_*) ;;
  *)
    echo "[Error] Refusing to remove unexpected restore workspace: $restore_dir" >&2
    return 1
    ;;
  esac

  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$TMP_DIR" "restore temporary directory" || return 1
    runtime_state_path_guard_if_declared "$restore_dir" "restore temporary workspace" || return 1
  fi
  if ! declare -F safe_rm_rf >/dev/null 2>&1; then
    echo "[Error] Safe restore workspace cleanup is unavailable." >&2
    return 1
  fi
  safe_rm_rf "$restore_dir" "$TMP_DIR"
}

function _backup_make_private_restore_dir() {
  local __out_var="${1:-}"
  require_valid_var_name "$__out_var" || return 1
  _backup_ensure_runtime_defaults

  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$TMP_DIR" "restore temporary directory" || return 1
  fi
  if [ ! -d "$TMP_DIR" ]; then
    echo "[Error] Restore temporary directory is unavailable: $TMP_DIR" >&2
    return 1
  fi

  local created_restore_dir="" old_umask
  old_umask="$(umask)"
  umask 077
  if ! created_restore_dir="$(mktemp -d "${TMP_DIR%/}/restore_XXXXXX")"; then
    umask "$old_umask"
    echo "[Error] Failed to create private restore workspace under $TMP_DIR" >&2
    return 1
  fi
  umask "$old_umask"

  if ! chmod 700 "$created_restore_dir" 2>/dev/null; then
    _backup_remove_private_restore_dir "$created_restore_dir" || true
    echo "[Error] Failed to secure private restore workspace: $created_restore_dir" >&2
    return 1
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$created_restore_dir" "restore temporary workspace" || {
      _backup_remove_private_restore_dir "$created_restore_dir" || true
      return 1
    }
  fi

  printf -v "$__out_var" '%s' "$created_restore_dir"
}

function _validate_backup_directory_tree_safe() {
  local source_dir="${1:-}" unsafe_entry=""
  if [ ! -d "$source_dir" ] || [ -L "$source_dir" ]; then
    echo "[Error] Backup directory snapshot is not a physical directory: $source_dir" >&2
    return 1
  fi

  if ! unsafe_entry="$(find "$source_dir" -mindepth 1 \( -type l -o \( ! -type d ! -type f \) \) -print -quit 2>/dev/null)"; then
    echo "[Error] Failed to inspect backup directory snapshot: $source_dir" >&2
    return 1
  fi
  if [ -n "$unsafe_entry" ]; then
    echo "[Error] Backup directory contains a symlink or special filesystem object: $unsafe_entry" >&2
    return 1
  fi
}

function _backup_directory_identity() {
  local path="${1:-}" stat_path="" identity=""
  [ -n "$path" ] || return 1
  if [ ! -d "$path" ] || [ -L "$path" ]; then
    return 1
  fi

  stat_path="$path"
  case "$stat_path" in
  -*) stat_path="./$stat_path" ;;
  esac

  if identity="$(trap - ERR; command stat -c '%d:%i' -- "$stat_path" 2>/dev/null || exit 1)"; then
    :
  elif identity="$(trap - ERR; command stat -f '%d:%i' "$stat_path" 2>/dev/null || exit 1)"; then
    :
  else
    return 1
  fi

  case "$identity" in
  "" | *[!0-9:]* | *:*:*) return 1 ;;
  *:*) ;;
  *) return 1 ;;
  esac
  printf '%s\n' "$identity"
}

function _snapshot_backup_directory_for_restore() {
  local __out_var="${1:-}" source_dir="${2:-}" restore_dir="${3:-}"
  require_valid_var_name "$__out_var" || return 1
  if [ ! -d "$source_dir" ] || [ -L "$source_dir" ]; then
    echo "[Error] Backup path is not a physical directory: $source_dir" >&2
    return 1
  fi
  [ -d "$restore_dir" ] || return 1

  local source_physical="" restore_physical="" current_physical=""
  local source_identity="" source_recheck_identity="" source_after_identity=""
  if ! source_identity="$(_backup_directory_identity "$source_dir")"; then
    echo "[Error] Failed to identify physical backup directory: $source_dir" >&2
    return 1
  fi
  source_physical="$(cd "$source_dir" 2>/dev/null && pwd -P && printf '.')" || return 1
  source_physical="${source_physical%$'\n.'}"
  restore_physical="$(cd "$restore_dir" 2>/dev/null && pwd -P && printf '.')" || return 1
  restore_physical="${restore_physical%$'\n.'}"
  if [ -L "$source_dir" ]; then
    echo "[Error] Backup directory changed to a symlink while preparing the restore snapshot: $source_dir" >&2
    return 1
  fi
  case "$restore_physical" in
  "$source_physical" | "$source_physical"/*)
    echo "[Error] Refusing to create a restore snapshot inside its source directory: $source_dir" >&2
    return 1
    ;;
  esac

  local snapshot_dir="${restore_dir%/}/directory"
  if ! mkdir -m 700 "$snapshot_dir" 2>/dev/null; then
    echo "[Error] Failed to create private backup directory snapshot." >&2
    return 1
  fi

  if ! source_recheck_identity="$(_backup_directory_identity "$source_dir")" ||
    [ "$source_recheck_identity" != "$source_identity" ]; then
    echo "[Error] Backup directory changed identity while preparing the restore snapshot: $source_dir" >&2
    return 1
  fi

  # Run cp from the opened source directory so later pathname replacement does
  # not redirect traversal. Verify the second open has the same physical path
  # and device/inode identity captured above. -P preserves links for fail-closed
  # validation below, and the final identity checks reject a pathname swap that
  # occurs during the copy.
  if ! (
    cd "$source_dir" &&
      current_physical="$(pwd -P && printf '.')" &&
      [ "${current_physical%$'\n.'}" = "$source_physical" ] &&
      [ "$(_backup_directory_identity .)" = "$source_identity" ] &&
      COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 cp -RP . "$snapshot_dir/" &&
      [ "$(_backup_directory_identity .)" = "$source_identity" ]
  ); then
    echo "[Error] Failed to snapshot backup directory: $source_dir" >&2
    return 1
  fi
  if ! source_after_identity="$(_backup_directory_identity "$source_dir")" ||
    [ "$source_after_identity" != "$source_identity" ]; then
    echo "[Error] Backup directory changed identity while creating the restore snapshot: $source_dir" >&2
    return 1
  fi
  _validate_backup_directory_tree_safe "$snapshot_dir" || return 1
  printf -v "$__out_var" '%s' "$snapshot_dir"
}

function _snapshot_backup_archive_for_restore() {
  local __out_var="${1:-}" archive="${2:-}" restore_dir="${3:-}"
  require_valid_var_name "$__out_var" || return 1
  [ -f "$archive" ] || return 1
  [ -d "$restore_dir" ] || return 1

  local snapshot_dir="${restore_dir%/}/archive" snapshot_path="" old_umask
  if ! mkdir -m 700 "$snapshot_dir" 2>/dev/null; then
    echo "[Error] Failed to create private backup archive snapshot directory." >&2
    return 1
  fi
  snapshot_path="${snapshot_dir}/archive.tar.gz"

  old_umask="$(umask)"
  umask 077
  # Shell redirection opens the operator-supplied pathname once. Validation and
  # extraction use only the private regular-file snapshot created from that FD.
  if ! cat <"$archive" >"$snapshot_path"; then
    umask "$old_umask"
    rm -f "$snapshot_path"
    echo "[Error] Failed to snapshot backup archive: $archive" >&2
    return 1
  fi
  umask "$old_umask"

  if [ ! -f "$snapshot_path" ] || [ -L "$snapshot_path" ] || ! chmod 400 "$snapshot_path" 2>/dev/null; then
    rm -f "$snapshot_path"
    echo "[Error] Failed to secure backup archive snapshot." >&2
    return 1
  fi
  _verify_backup_archive_checksum_if_present "$archive" "$snapshot_path" || return 1
  printf -v "$__out_var" '%s' "$snapshot_path"
}

function _tar_archive_is_noop_backup() {
  local archive="${1:-}" listing="" detailed_listing="" entry="" line="" type=""
  local count=0 detailed_count=0
  [ -f "$archive" ] || return 1

  if ! listing="$(LC_ALL=C tar -tzf "$archive" 2>/dev/null)"; then
    return 1
  fi
  if [ -z "$listing" ]; then
    return 0
  fi

  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    case "$entry" in
    . | ./) ;;
    *) return 1 ;;
    esac
    count=$((count + 1))
    [ "$count" -le 1 ] || return 1
  done <<<"$listing"
  [ "$count" -eq 1 ] || return 1

  if ! detailed_listing="$(LC_ALL=C tar -tzvf "$archive" 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    detailed_count=$((detailed_count + 1))
    type="${line:0:1}"
    case "$type" in
    # BSD no-op fallback emits a directory entry for "."; PAX metadata is harmless.
    d | x | g | L | K) ;;
    *) return 1 ;;
    esac
    case "$line" in
    *" -> "* | *" link to "*) return 1 ;;
    esac
  done <<<"$detailed_listing"

  [ "$detailed_count" -ge 1 ]
}

function _validate_tar_entries_safe() {
  local archive="${1:-}"
  [ -f "$archive" ] || return 1

  if _tar_archive_is_noop_backup "$archive"; then
    return 0
  fi

  local entry found=false
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    found=true
    case "$entry" in
    /* | \\*) return 1 ;;
    [A-Za-z]:* | [A-Za-z]:\\*) return 1 ;;
    . | ./ | .. | ../) return 1 ;;
    *../* | ../* | */..) return 1 ;;
    esac
  done < <(LC_ALL=C tar -tzf "$archive" 2>/dev/null)

  [ "$found" = true ] || return 1

  local listing_line type detailed_found=false
  while IFS= read -r listing_line; do
    [ -z "$listing_line" ] && continue
    detailed_found=true
    type="${listing_line:0:1}"
    case "$type" in
    # Metadata-only headers do not restore as filesystem objects.
    - | d | x | g | L | K) ;;
    *) return 1 ;;
    esac
    case "$listing_line" in
    *" -> "* | *" link to "*) return 1 ;;
    esac
  done < <(LC_ALL=C tar -tzvf "$archive" 2>/dev/null)

  [ "$detailed_found" = true ]
}

function _safe_extract_tar() {
  local archive="${1:-}" target_dir="${2:-}"
  if [ -z "$archive" ] || [ -z "$target_dir" ]; then
    echo "[Error] _safe_extract_tar requires archive and target_dir" >&2
    return 1
  fi
  if ! _validate_tar_entries_safe "$archive"; then
    echo "[Error] Backup archive contains unsafe paths or member types: $archive" >&2
    return 1
  fi
  mkdir -p "$target_dir" || return 1
  if _tar_archive_is_noop_backup "$archive"; then
    return 0
  fi

  local old_umask tar_version=""
  old_umask="$(umask)"
  umask 077
  tar_version="$(LC_ALL=C tar --version 2>/dev/null || true)"
  if printf '%s\n' "$tar_version" | grep -qi 'gnu tar'; then
    if LC_ALL=C tar -xzf "$archive" -C "$target_dir" --no-same-owner --no-same-permissions 2>/dev/null; then
      umask "$old_umask"
      return 0
    fi
    umask "$old_umask"
    echo "[Error] Failed to extract backup archive with GNU tar safety flags: $archive" >&2
    return 1
  fi
  if printf '%s\n' "$tar_version" | grep -Eqi 'bsdtar|libarchive'; then
    if LC_ALL=C tar -xozf "$archive" -C "$target_dir" 2>/dev/null; then
      umask "$old_umask"
      return 0
    fi
    umask "$old_umask"
    echo "[Error] Failed to extract backup archive with BSD tar safety flags: $archive" >&2
    return 1
  fi
  if [ -z "$tar_version" ]; then
    umask "$old_umask"
    echo "[Error] Unable to identify tar implementation for safe extraction." >&2
    return 1
  fi
  umask "$old_umask"
  echo "[Error] Unsupported tar implementation for safe extraction: $(printf '%s' "$tar_version" | head -n 1)" >&2
  return 1
}
