# shellcheck shell=bash

# Configuration helpers are also sourced directly, before the command modules.
if ! declare -F __dockistrate_permissions_common_loaded >/dev/null 2>&1; then
  # shellcheck source=../permissions/common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../permissions" && pwd)/common.sh"
fi
if ! declare -F _permissions_metadata_stat >/dev/null 2>&1; then
  # shellcheck source=../permissions/metadata_transaction.sh
  source "${PERMISSIONS_COMMON_DIR}/metadata_transaction.sh"
fi

function _global_settings_staging_directory_metadata() {
  local directory="${1:-}"
  local PERMISSIONS_STAT_DEVICE="" PERMISSIONS_STAT_INODE="" PERMISSIONS_STAT_UID=""
  local PERMISSIONS_STAT_GID="" PERMISSIONS_STAT_MODE="" PERMISSIONS_STAT_LINKS=""
  local PERMISSIONS_STAT_TYPE="" PERMISSIONS_NORMALIZED_MODE=""
  _runtime_path_reject_symlink_prefix_components "$directory" "settings staging directory" &&
    runtime_state_path_guard_if_declared "$directory" "settings staging directory" || return 1
  if ! _permissions_metadata_stat "$directory" || [ "$PERMISSIONS_STAT_TYPE" != directory ] ||
    [ "$PERMISSIONS_STAT_MODE" != 700 ] || [ "$PERMISSIONS_STAT_UID" != "$EUID" ]; then
    echo '[Error] Unable to verify private settings staging directory.' >&2
    return 1
  fi
  # Directory link counts can change when a file is created inside them.
  # Identity and access checks use only metadata that this staging operation
  # must preserve; regular settings files still require exactly one link.
  printf '%s %s %s %s %s\n' "$PERMISSIONS_STAT_DEVICE" "$PERMISSIONS_STAT_INODE" \
    "$PERMISSIONS_STAT_UID" "$PERMISSIONS_STAT_GID" "$PERMISSIONS_STAT_MODE"
}

function _global_settings_cleanup_staging() {
  local directory="${1:-}" file="${2:-}" failed=false
  if [ -n "$file" ] && ! rm -f "$file"; then failed=true; fi
  if [ -n "$directory" ] && ! rmdir "$directory"; then failed=true; fi
  if [ "$failed" = true ]; then
    echo "[Error] Unable to remove settings staging directory: $directory" >&2
    return 1
  fi
}

# Publish only a private, operation-owned temporary file whose ownership and
# permissions have been verified. Existing settings retain their owner/group
# and any access restrictions tighter than the documented 0640 ceiling.
function _finalize_global_settings_file() {
  local target="${1:-}" tmp="${2:-}" expected_target="${3:-}" expected_tmp="${4:-}"
  local expected_directory="${5:-}" directory="${tmp%/*}" directory_current=""
  local current="" wanted=640 device="" inode="" owner="" group="" mode="" links=""
  local tmp_device="" tmp_inode="" tmp_owner="" tmp_group="" tmp_mode="" tmp_links=""
  [ -n "$target" ] && [ -n "$tmp" ] && [ -n "$expected_target" ] &&
    [ -n "$expected_tmp" ] && [ -n "$expected_directory" ] || return 1
  directory_current="$(_global_settings_staging_directory_metadata "$directory" || exit 1)" || return 1
  if [ "$directory_current" != "$expected_directory" ]; then
    echo '[Error] Private settings staging directory identity or permissions changed.' >&2
    return 1
  fi
  current="$(_global_settings_file_metadata "$tmp" || exit 1)" || return 1
  if [ "$current" != "$expected_tmp" ]; then
    echo '[Error] Temporary global settings identity or permissions changed.' >&2
    return 1
  fi
  IFS=' ' read -r tmp_device tmp_inode tmp_owner tmp_group tmp_mode tmp_links <<<"$current"
  owner="$tmp_owner"
  # The private directory retains the destination parent's inherited group,
  # even after clearing its setgid bit to enforce exact mode 0700.
  IFS=' ' read -r device inode tmp_owner group mode <<<"$expected_directory"
  if [ "$expected_target" != missing ]; then
    IFS=' ' read -r device inode owner group mode links <<<"$expected_target"
    wanted="$(_permissions_intersect_mode "$mode" 640 || exit 1)" || return 1
  fi
  if [ "$tmp_owner:$tmp_group" != "$owner:$group" ]; then
    if ! chown "$owner:$group" "$tmp" 2>/dev/null; then
      echo '[Error] Unable to retain global settings ownership.' >&2
      return 1
    fi
  fi
  if [ "$tmp_mode" != "$wanted" ] && ! chmod "$wanted" "$tmp" 2>/dev/null; then
    echo '[Error] Unable to protect temporary global settings.' >&2
    return 1
  fi
  current="$(_global_settings_file_metadata "$tmp" || exit 1)" || return 1
  if [ "$current" != "$tmp_device $tmp_inode $owner $group $wanted $tmp_links" ]; then
    echo '[Error] Unable to verify temporary global settings ownership and permissions.' >&2
    return 1
  fi
  current="$(_global_settings_file_snapshot "$target" || exit 1)" || return 1
  if [ "$current" != "$expected_target" ]; then
    echo '[Error] Global settings changed while preparing their replacement.' >&2
    return 1
  fi
  directory_current="$(_global_settings_staging_directory_metadata "$directory" || exit 1)" || return 1
  if [ "$directory_current" != "$expected_directory" ]; then
    echo '[Error] Private settings staging directory identity or permissions changed.' >&2
    return 1
  fi
  mv -f "$tmp" "$target" || return 1
  current="$(_global_settings_file_metadata "$target" || exit 1)" || return 1
  if [ "$current" != "$tmp_device $tmp_inode $owner $group $wanted $tmp_links" ] ||
    [ -e "$tmp" ] || [ -L "$tmp" ]; then
    echo '[Error] Unable to verify published global settings.' >&2
    return 1
  fi
}
