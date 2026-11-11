# shellcheck shell=bash

# Explicit targets mirror a pre-change snapshot. Direct internal calls without
# targets retain the historical overlay behavior.
function restore_backup_archive() {
  _backup_ensure_runtime_defaults
  local archive="${1:-}"
  shift || true
  if [ ! -f "$archive" ]; then
    echo "[Error] Rollback archive is missing: $archive" >&2
    return 1
  fi
  local _replay_root="" _replay_workspace="" archive_snapshot=""
  local _replay_paths=() _replay_slots=() _replay_changed=() _replay_targets=()
  local _replay_dir_paths=() _replay_dir_sources=() _replay_dir_refs=()
  local target="" normalized="" existing="" entry="" list="" mirror=false
  local original_missing=false skip=false failed=false old_umask="" workspace_group=""
  _replay_root="$(_realpath_portable "${STATE_DIR:-$BASE_DIR}" && printf '.')" || return 1
  _replay_root="${_replay_root%.}"
  [ "$_replay_root" != / ] || return 1
  [ -d "$_replay_root" ] && [ ! -L "${STATE_DIR:-$BASE_DIR}" ] || return 1
  [ "$#" -eq 0 ] || mirror=true
  for target in "$@"; do
    normalized="$(_rollback_replay_normalize_target "$target" && printf '.')" || return 1
    normalized="${normalized%.}"
    _rollback_replay_check_path "$normalized" || {
      echo "[Error] Unsafe rollback target: $target" >&2
      return 1
    }
    skip=false
    for existing in "${_replay_targets[@]-}"; do
      [ -n "$existing" ] || continue
      case "$normalized" in "$existing" | "$existing"/*) skip=true ;; esac
    done
    [ "$skip" = false ] || continue
    local kept_targets=()
    for existing in "${_replay_targets[@]-}"; do
      [ -n "$existing" ] || continue
      case "$existing" in "$normalized"/*) ;; *) kept_targets+=("$existing") ;; esac
    done
    _replay_targets=()
    for existing in "${kept_targets[@]-}"; do
      [ -n "$existing" ] && _replay_targets+=("$existing")
    done
    _replay_targets+=("$normalized")
  done

  # The OS temporary root is outside state, including TMP_DIR when uninstall
  # snapshots it. Refuse a state root that would contain our staging workspace.
  old_umask="$(umask)"
  umask 077
  _replay_workspace="$(mktemp -d /tmp/dockistrate_rollback.XXXXXX)" || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"
  _replay_workspace="$(cd "$_replay_workspace" && pwd -P && printf '.')" || return 1
  _replay_workspace="${_replay_workspace%$'\n.'}"
  case "$_replay_workspace" in
  "$_replay_root" | "$_replay_root"/*)
    _rollback_replay_cleanup_workspace || true
    echo "[Error] Rollback staging must be outside the state root." >&2
    return 1
    ;;
  esac
  # Darwin inherits the parent's group even without setgid. A workspace under
  # /tmp can otherwise inherit wheel, silently losing setgid during extraction
  # or metadata journaling by an operator who does not belong to that group.
  if ! workspace_group="$(id -g)" || ! chgrp "$workspace_group" "$_replay_workspace"; then
    _rollback_replay_cleanup_workspace || true
    echo "[Error] Failed to prepare the rollback staging group." >&2
    return 1
  fi
  if ! _snapshot_backup_archive_for_restore archive_snapshot "$archive" "$_replay_workspace" ||
    ! mkdir -m 700 "$_replay_workspace/extracted" ||
    ! _safe_extract_transaction_tar "$archive_snapshot" "$_replay_workspace/extracted"; then
    _rollback_replay_cleanup_workspace || true
    return 1
  fi
  list="$_replay_workspace/entries"
  if [ "$mirror" = true ]; then
    find "$_replay_workspace/extracted" -mindepth 1 -print0 >"$list" || failed=true
    while IFS= read -r -d '' entry; do
      if ! _rollback_stage_in_scope "$entry"; then
        echo "[Error] Rollback archive contains an entry outside its targets: $entry" >&2
        failed=true
      fi
    done <"$list"
    for target in "${_replay_targets[@]-}"; do
      [ -n "$target" ] || continue
      entry="$_replay_workspace/extracted/${target#"$_replay_root/"}"
      original_missing=false
      for existing in "${ROLLBACK_NEW_FILES[@]-}"; do
        [ -n "$existing" ] || continue
        # Match the same physical path used for targets, including macOS's
        # /tmp -> /private/tmp system alias.
        if ! normalized="$(_rollback_replay_normalize_target "$existing" && printf '.')"; then
          failed=true
          continue
        fi
        normalized="${normalized%.}"
        if [ "$target" = "$normalized" ]; then original_missing=true; fi
      done
      if [ "$original_missing" = false ] && [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
        echo "[Error] Rollback archive is missing target: $target" >&2
        failed=true
      fi
    done
  else
    find "$_replay_workspace/extracted" -mindepth 1 -maxdepth 1 -print0 >"$list" || failed=true
    while IFS= read -r -d '' entry; do
      _replay_targets+=("$_replay_root/${entry##*/}")
    done <"$list"
  fi
  if [ "$failed" = true ]; then
    _rollback_replay_cleanup_workspace || true
    return 1
  fi

  for target in "${_replay_targets[@]-}"; do
    [ -n "$target" ] || continue
    entry="$_replay_workspace/extracted/${target#"$_replay_root/"}"
    if ! _rollback_replay_entry "$entry" "$target" "$mirror"; then
      failed=true
      break
    fi
  done
  if [ "$failed" = false ] && ! _rollback_replay_apply_directory_metadata; then
    echo "[Error] Failed to restore rollback directory metadata." >&2
    failed=true
  fi
  if [ "$failed" = true ]; then
    if _rollback_replay_undo && _rollback_replay_cleanup_slots &&
      _rollback_replay_apply_directory_metadata true; then
      echo "[Error] Rollback replay failed; the state present before replay was restored." >&2
    else
      echo "[Error] Rollback replay and recovery failed; retained files require manual recovery." >&2
      _rollback_replay_report_slots
    fi
    echo "[Error] Retained validated rollback snapshot: $_replay_workspace" >&2
    return 1
  fi
  # Removing sibling slots changes parent timestamps and requires write access.
  # Reapply snapshot metadata afterward; a finalization error remains explicit
  # and retains the validated snapshot for manual recovery.
  if ! _rollback_replay_prepare_directory_access || ! _rollback_replay_cleanup_slots; then
    failed=true
  fi
  if ! _rollback_replay_apply_directory_metadata; then failed=true; fi
  if [ "$failed" = true ]; then
    _rollback_replay_report_slots
    echo "[Error] Rollback files restored, but metadata or private recovery cleanup failed: $_replay_workspace" >&2
    return 1
  fi
  _rollback_replay_cleanup_workspace
}
