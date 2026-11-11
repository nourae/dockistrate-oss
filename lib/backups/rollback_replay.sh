# shellcheck shell=bash

# Private sibling slots make displacements same-filesystem renames. Existing
# directories stay in place to retain Docker bind mounts. Journal arrays are
# local to restore_backup_archive and shared through Bash's dynamic scope.
function _rollback_replay_normalize_target() {
  local target="${1:-}" normalized=""
  if [ -e "$target" ] || [ -L "$target" ]; then
    # A leaf symlink is replayed as an entry, never followed to its target.
    _normalize_delete_target_path "$target"
  else
    # An operation can fail before creating any of a new domain's parents.
    # Resolve the existing prefix without requiring or creating those parents.
    normalized="$(_normalize_transaction_backup_target "$target")" || return 1
    case "/$normalized/" in */../* | */./*) return 1 ;; esac
    printf '%s' "$normalized"
  fi
}

# shellcheck disable=SC2154
function _rollback_replay_check_path() {
  local path="${1:-}" parent=""
  case "$path" in "$_replay_root"/*) ;; *) return 1 ;; esac
  parent="${path%/*}"
  while [ "$parent" != "$_replay_root" ]; do
    [ ! -L "$parent" ] || return 1
    if [ -e "$parent" ] && [ ! -d "$parent" ]; then return 1; fi
    parent="${parent%/*}"
  done
  [ -d "$_replay_root" ] && [ ! -L "$_replay_root" ]
}

function _rollback_replay_replace() {
  local source="${1:-}" destination="${2:-}" make_directory="${3:-false}"
  local slot="" index="${#_replay_paths[@]}"
  _rollback_replay_check_path "$destination" || return 1
  if declare -F _domain_config_shared_file_replay_protected >/dev/null 2>&1 &&
    _domain_config_shared_file_replay_protected "$destination"; then
    return 0
  fi
  slot="$(mktemp -d "${destination%/*}/.dockistrate-rollback.XXXXXX")" || return 1
  _replay_paths+=("$destination")
  _replay_slots+=("$slot")
  _replay_changed+=(false)
  # Prepare the replacement before moving any live entry; never follow links.
  if [ "$make_directory" = true ]; then
    mkdir -m 700 "$slot/new" || return 1
  elif [ -n "$source" ] && { [ -e "$source" ] || [ -L "$source" ]; }; then
    COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 cp -pRP "$source" "$slot/new" || return 1
    if [ -d "$slot/new" ] && [ ! -L "$slot/new" ]; then
      # Moving a directory between parents can require permission to update '..'.
      chmod u+rwx "$slot/new" || return 1
    fi
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    if [ -d "$destination" ] && [ ! -L "$destination" ]; then
      mkdir -m 700 "$slot/old-directory-metadata" || return 1
      _rollback_replay_copy_directory_metadata "$destination" "$slot/old-directory-metadata" || return 1
      : >"$slot/old-directory-metadata.ready" || return 1
      chmod u+rwx "$destination" || return 1
    fi
    mv "$destination" "$slot/old" || return 1
  fi
  _replay_changed[index]=true
  if [ -f "$slot/old-directory-metadata.ready" ]; then
    _rollback_replay_copy_directory_metadata "$slot/old-directory-metadata" "$slot/old" || return 1
  fi
  if [ -e "$slot/new" ] || [ -L "$slot/new" ]; then
    mv "$slot/new" "$destination" || return 1
    if [ -d "$source" ] && [ ! -L "$source" ]; then
      _rollback_replay_copy_directory_metadata "$source" "$destination" || return 1
    fi
  fi
  return 0
}

function _rollback_replay_ensure_parent() {
  local parent="${1%/*}"
  [ "$parent" = "$_replay_root" ] && return 0
  [ ! -L "$parent" ] || return 1
  if [ -d "$parent" ]; then return 0; fi
  [ ! -e "$parent" ] || return 1
  _rollback_replay_ensure_parent "$parent" || return 1
  _rollback_replay_replace "" "$parent" true
}

function _rollback_replay_directory_mode() {
  local path="${1:-}" mode=""
  mode="$(stat -c '%a' "$path" 2>/dev/null)" ||
    mode="$(stat -f '%p' "$path" 2>/dev/null)" || return 1
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  # BSD %Lp omits special bits; %p includes them and the file type. Five octal
  # digits also tell GNU chmod to clear any special bits absent in the snapshot.
  printf '%05o\n' "$((8#$mode & 07777))"
}

# Restore exact snapshot permissions rather than applying the runtime permission
# policy. Ownership remains unchanged; timestamps come from the validated source.
function _rollback_replay_copy_directory_metadata() {
  local source="${1:-}" destination="${2:-}" mode="" applied_mode=""
  [ -d "$source" ] && [ ! -L "$source" ] &&
    [ -d "$destination" ] && [ ! -L "$destination" ] || return 1
  mode="$(_rollback_replay_directory_mode "$source")" || return 1
  chmod "$mode" "$destination" || return 1
  touch -r "$source" "$destination" || return 1
  # chmod can succeed while silently discarding special bits. Do not report a
  # complete copy or journal unusable recovery metadata in that case.
  applied_mode="$(_rollback_replay_directory_mode "$destination")" || return 1
  [ "$applied_mode" = "$mode" ]
}

# Save live metadata before enumeration or sibling-slot creation changes it.
# These arrays are local to restore_backup_archive, like the displacement log.
# shellcheck disable=SC2154
function _rollback_replay_record_directory() {
  local source="${1:-}" destination="${2:-}" reference=""
  reference="$(mktemp -d "$_replay_workspace/metadata.XXXXXX")" || return 1
  _rollback_replay_copy_directory_metadata "$destination" "$reference" || return 1
  _replay_dir_paths+=("$destination")
  _replay_dir_sources+=("$source")
  _replay_dir_refs+=("$reference")
  # The original mode is journaled before temporarily allowing child replay.
  chmod u+rwx "$destination"
}

function _rollback_replay_prepare_directory_access() {
  local destination=""
  # Parents precede children, including directories whose archived mode is read-only.
  for destination in "${_replay_dir_paths[@]-}"; do
    [ -n "$destination" ] || continue
    _rollback_replay_check_path "$destination" &&
      [ -d "$destination" ] && [ ! -L "$destination" ] &&
      chmod u+rwx "$destination" || return 1
  done
}

function _rollback_replay_apply_directory_metadata() {
  local previous="${1:-false}" index="${#_replay_dir_paths[@]}" source="" destination=""
  # Children precede parents so restoring a restrictive parent mode cannot hide them.
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    destination="${_replay_dir_paths[index]}"
    source="${_replay_dir_sources[index]}"
    [ "$previous" != true ] || source="${_replay_dir_refs[index]}"
    _rollback_replay_check_path "$destination" &&
      _rollback_replay_copy_directory_metadata "$source" "$destination" || return 1
  done
}

# _replay_workspace is local to restore_backup_archive.
# shellcheck disable=SC2154
function _rollback_replay_entry() {
  local source="${1:-}" destination="${2:-}" mirror="${3:-true}"
  local source_list="" destination_list="" entry="" name=""
  _rollback_replay_check_path "$destination" || return 1
  if [ ! -e "$source" ] && [ ! -L "$source" ] &&
    [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
    return 0
  fi
  if [ -d "$source" ] && [ ! -L "$source" ] &&
    [ -d "$destination" ] && [ ! -L "$destination" ]; then
    _rollback_replay_record_directory "$source" "$destination" || return 1
    source_list="$(mktemp "$_replay_workspace/source.XXXXXX")" || return 1
    destination_list="$(mktemp "$_replay_workspace/destination.XXXXXX")" || return 1
    # Capture both lists before adding journal slots inside these directories.
    find "$source" -mindepth 1 -maxdepth 1 -print0 >"$source_list" || return 1
    find "$destination" -mindepth 1 -maxdepth 1 -print0 >"$destination_list" || return 1
    while IFS= read -r -d '' entry; do
      name="${entry##*/}"
      _rollback_replay_entry "$entry" "$destination/$name" "$mirror" || return 1
    done <"$source_list"
    if [ "$mirror" = true ]; then
      while IFS= read -r -d '' entry; do
        name="${entry##*/}"
        if [ ! -e "$source/$name" ] && [ ! -L "$source/$name" ]; then
          _rollback_replay_replace "" "$entry" || return 1
        fi
      done <"$destination_list"
    fi
    return 0
  fi
  _rollback_replay_ensure_parent "$destination" || return 1
  _rollback_replay_replace "$source" "$destination"
}

function _rollback_replay_undo() {
  local index="${#_replay_paths[@]}" destination="" slot=""
  _rollback_replay_prepare_directory_access || return 1
  while [ "$index" -gt 0 ]; do
    index=$((index - 1))
    destination="${_replay_paths[index]}"
    slot="${_replay_slots[index]}"
    if ! _rollback_replay_check_path "$destination"; then return 1; fi
    if [ "${_replay_changed[index]}" != true ]; then
      # A failed displacement may have temporarily opened the original directory.
      if [ -f "$slot/old-directory-metadata.ready" ]; then
        _rollback_replay_copy_directory_metadata "$slot/old-directory-metadata" "$destination" || return 1
      fi
      continue
    fi
    if [ -d "$destination" ] && [ ! -L "$destination" ]; then
      _rollback_replay_remove_private_tree "$destination" "$_replay_root" || return 1
    elif ! safe_rm_rf "$destination" "$_replay_root"; then
      # Stop before undoing an ancestor: removing it could destroy a child slot
      # that still contains the only displaced copy after this recovery error.
      return 1
    fi
    if [ -e "$slot/old" ] || [ -L "$slot/old" ]; then
      if [ -f "$slot/old-directory-metadata.ready" ]; then chmod u+rwx "$slot/old" || return 1; fi
      mv "$slot/old" "$destination" || return 1
      if [ -f "$slot/old-directory-metadata.ready" ]; then
        _rollback_replay_copy_directory_metadata "$slot/old-directory-metadata" "$destination" || return 1
      fi
    fi
  done
  return 0
}

function _rollback_replay_cleanup_slots() {
  local slot="" failed=false
  for slot in "${_replay_slots[@]-}"; do
    [ -n "$slot" ] || continue
    _rollback_replay_remove_private_tree "$slot" "$_replay_root" || failed=true
  done
  [ "$failed" = false ]
}

function _rollback_replay_report_slots() {
  local slot=""
  for slot in "${_replay_slots[@]-}"; do
    [ -n "$slot" ] || continue
    [ -d "$slot" ] || continue
    echo "[Error] Retained rollback recovery files: $slot" >&2
  done
}

function _rollback_replay_remove_private_tree() {
  local path="${1:-}" boundary="${2:-}" failures=""
  [ -e "$path" ] || [ -L "$path" ] || return 0
  path="$(_safe_delete_validate_target "$path" "$boundary" && printf '.')" || return 1
  path="${path%.}"
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  # Archived directories can be read-only. Walk physical directories in preorder
  # so cleanup works for their owner without following any archived symlink.
  failures="$(find "$path" -type d ! -exec chmod u+rwx {} \; -print)" || return 1
  [ -z "$failures" ] || return 1
  safe_rm_rf "$path" "$boundary"
}

function _rollback_replay_cleanup_workspace() {
  _rollback_replay_remove_private_tree "$_replay_workspace" "$_replay_workspace"
}

function _rollback_stage_in_scope() {
  local entry="${1:-}" target="" relative="${1#"$_replay_workspace/extracted/"}"
  for target in "${_replay_targets[@]-}"; do
    [ -n "$target" ] || continue
    case "$_replay_root/$relative" in "$target" | "$target"/*) return 0 ;; esac
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      case "$target" in "$_replay_root/$relative"/*) return 0 ;; esac
    fi
  done
  return 1
}
