# shellcheck shell=bash

function _backup_prepare_deferred_domain_backup() {
  local saved="$1/automatic_backup" marker="" name=""
  runtime_state_paths_guard_if_declared "$saved" "$FULL_BACKUP_FILE" "$FULL_BACKUP_CHECKSUM_FILE" || return 1
  (umask 077; mkdir -p "$saved") || return 1
  for name in pointer checksum; do
    marker="$FULL_BACKUP_FILE"
    [ "$name" != checksum ] || marker="$FULL_BACKUP_CHECKSUM_FILE"
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
      cp -p "$marker" "$saved/$name" || return 1
      _domain_runtime_put "$saved/state.csv" "$name" present || return 1
    else
      _domain_runtime_put "$saved/state.csv" "$name" absent || return 1
    fi
  done
  printf 'ready\n' >"$saved/ready"
}

function _backup_flush_deferred_domain_backup() {
  local journal="${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" requested=""
  [ -n "$journal" ] || return 0
  requested="$(_domain_runtime_get "$journal/transaction.csv" auto_backup_requested no)" || return 1
  [ "$requested" = yes ] || return 0
  if [ "${DOMAIN_CONFIG_TERMINAL_UNINSTALL:-false}" = true ]; then
    # The command dispatcher scopes this flag, and source publication has
    # already verified the terminal uninstall's empty export. No restorable
    # post-change payload remains; preserve the preceding useful backup.
    [ "${DOMAIN_CONFIG_MUTATION_COMMAND:-}" = uninstall-all ] &&
      [ ! -e "$CONFIG_DIR" ] && [ ! -L "$CONFIG_DIR" ] || return 1
    return 0
  fi
  _backup_prepare_deferred_domain_backup "$journal" || return 1
  local DOMAIN_CONFIG_AUTO_BACKUP_FLUSH=true
  create_backup "" "${ROLLBACK_DESC:-Auto}"
}

function _backup_finish_deferred_domain_backup() {
  local saved="$1/automatic_backup" output=""
  [ -f "$saved/ready" ] || return 0
  output="$(_domain_runtime_get "$saved/state.csv" output)" || return 1
  [ -n "$output" ] || return 0
  _backup_enforce_retention
}

# Runs only for an uncommitted journal while the mutation lock is still held.
# A committed transaction retains the full backup and discards this metadata.
function _backup_rollback_deferred_domain_backup() {
  local journal="$1" saved="$1/automatic_backup" marker="" name="" present="" output="" resolved=""
  [ -f "$saved/ready" ] || return 0
  runtime_state_paths_guard_if_declared "$saved" "$FULL_BACKUP_FILE" "$FULL_BACKUP_CHECKSUM_FILE" || return 1
  for name in pointer checksum; do
    marker="$FULL_BACKUP_FILE"
    [ "$name" != checksum ] || marker="$FULL_BACKUP_CHECKSUM_FILE"
    present="$(_domain_runtime_get "$saved/state.csv" "$name")" || return 1
    case "$present" in
    present)
      [ -f "$saved/$name" ] && [ ! -L "$saved/$name" ] || return 1
      cp -p "$saved/$name" "$marker" || return 1
      ;;
    absent) _backup_safe_rm_f "$marker" || return 1 ;;
    *) return 1 ;;
    esac
  done
  output="$(_domain_runtime_get "$saved/state.csv" output)" || return 1
  [ -n "$output" ] || return 0
  _backup_resolve_path_within_root resolved "$output" || return 1
  [ "$resolved" = "$output" ] || return 1
  case "${output##*/}" in *"_${journal##*.}") ;; *) return 1 ;; esac
  _backup_safe_rm_rf "$output" || return 1
  _backup_safe_rm_f "$output.tar.gz" || return 1
  _backup_safe_rm_f "$output.tar.gz.sha256"
}
