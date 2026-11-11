# shellcheck shell=bash
# Secure filesystem helpers populate inspection variables in the caller.
# shellcheck disable=SC2034

# Restore preserves unfinished drafts as opaque regular-file trees. These
# helpers deliberately do not relax the flat CSV model used by validation,
# candidate construction, or applied snapshots.
function _domain_config_draft_file_fingerprint() (
  local file="$1" before="" opened="" after="" digest=""
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  before="$(_restore_intake_stat "$file" false)" || return 1
  exec 3<"$file" || return 1
  opened="$(_restore_intake_fstat_regular <&3)" || return 1
  [ "$before" = "$opened" ] || return 1
  digest="$(cksum <&3)" || return 1
  after="$(_restore_intake_fstat_regular <&3)" || return 1
  [ "$opened" = "$after" ] && [ "$opened" = "$(_restore_intake_stat "$file" false)" ] || return 1
  printf '%s\n' "$digest"
)

# The caller pins the current directory. Recursing through the existing secure
# directory helper prevents an ancestor replacement from redirecting a read.
function _domain_config_draft_tree_walk() {
  local action="$1" destination="${2:-}" prefix="${3:-}" entry="" name="" relative="" digest="" bytes="" mode=""
  local LC_ALL=C
  for entry in ./* ./.[!.]* ./..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry#./}"; relative="${prefix:+$prefix/}$name"
    [ "$(_restore_intake_member_name "$relative")" = "$relative" ] || return 1
    _secure_fs_stat_path "$entry" || return 1
    case "$SECURE_FS_TYPE" in
    directory)
      if [ "$action" = copy ]; then
        [ ! -e "$destination/$relative" ] && [ ! -L "$destination/$relative" ] || return 1
        mkdir -m 700 "$destination/$relative" || return 1
      else
        csv_join_row directory "$relative" '' || return 1
      fi
      (
        _secure_fs_enter_directory "$name" existing || exit 1
        _domain_config_draft_tree_walk "$action" "$destination" "$relative"
      ) || return 1
      ;;
    file)
      if [ "$action" = copy ]; then
        bytes="$(_restore_intake_size "$entry")" || return 1
        mode="$(_restore_intake_file_mode "$entry")" || return 1
        printf -v mode '%o' "$((8#$mode))"
        [ ! -e "$destination/$relative" ] && [ ! -L "$destination/$relative" ] || return 1
        _restore_intake_copy_regular "$entry" "$destination/$relative" "$bytes" 'Domain draft' false || return 1
        _tighten_file_permissions "$destination/$relative" "$mode" || return 1
      else
        digest="$(_domain_config_draft_file_fingerprint "$entry")" || return 1
        csv_join_row file "$relative" "$digest" || return 1
      fi
      ;;
    *) _domain_config_error "Domain draft contains a symlink or special filesystem object: ${SECURE_FS_PATH%/}/$name"; return 1 ;;
    esac
  done
}

function _domain_config_draft_tree_fingerprint() (
  local directory="$1"
  runtime_state_path_guard_if_declared "$directory" 'domain draft' || return 1
  if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then printf 'missing\n'; return 0; fi
  _secure_fs_pin_directory "$directory" existing || return 1
  csv_join_row directory '' '' || return 1
  _domain_config_draft_tree_walk fingerprint
)

function _domain_config_draft_tree_guard() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  _domain_config_draft_tree_fingerprint "$1" >/dev/null
}

function _domain_config_draft_tree_copy() (
  local source="$1" destination="$2" before="" after="" entry=""
  [ "$source" != "$destination" ] || return 1
  case "$destination" in "$source"/*) return 1 ;; esac
  [ -d "$source" ] && [ ! -L "$source" ] || return 1
  before="$(_domain_config_draft_tree_fingerprint "$source")" || return 1
  runtime_state_path_guard_if_declared "$destination" 'domain draft snapshot' || return 1
  _secure_fs_pin_directory "$destination" create || return 1
  for entry in ./* ./.[!.]* ./..?*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || return 1
  done
  _secure_fs_pin_directory "$source" existing || return 1
  _domain_config_draft_tree_walk copy "$destination" || return 1
  after="$(_domain_config_draft_tree_fingerprint "$source")" || return 1
  [ "$before" = "$after" ] && [ "$before" = "$(_domain_config_draft_tree_fingerprint "$destination")" ] || {
    _domain_config_error "Domain draft changed while copying $source; preserving its current files."
    return 1
  }
)
