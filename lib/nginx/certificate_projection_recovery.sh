# shellcheck shell=bash

function _projection_capture() (
  local root="${1:-}" selected="" name="" raw="" identity="" device="" inode="" status=0
  selected="$(_projection_mount_source && printf '.')" || status=$?
  [ "$status" -eq 0 ] || return "$status"
  selected="${selected%.}"
  _secure_fs_pin_directory "$root" || return 1
  root="$SECURE_FS_PATH"
  identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  [ "$SECURE_FS_MODE:$SECURE_FS_UID" = "700:${EUID:-$(id -u)}" ] || return 3
  [ "${selected%/*}" = "$root" ] || return 3
  name="${selected##*/}"
  _projection_generation_name "$name" || return 3
  [ -d "./$name" ] && [ ! -L "./$name" ] || return 3
  raw="$(_projection_with_file "$selected/.dockistrate-projection" _projection_read_manifest_fd && printf '.')" || return $?
  raw="${raw%.}"
  _projection_verify_generation "$root" "$name" "$raw" || return $?
  _secure_fs_enter_directory "$name" || return 1
  device="$SECURE_FS_DEVICE" inode="$SECURE_FS_INODE"
  _projection_require_bound_root "$selected" "$device:$inode" && _projection_require_bound_root "$root" "$identity" || return 1
  printf 'dockistrate-projection-token-v2:'
  printf '%s' "$selected" | _projection_hex
  printf ':%s:%s:' "$device" "$inode"
  printf '%s' "$raw" | _projection_hex
  printf '\n'
)

function _projection_recover() (
  local projection_root="${1:-}" projection_stage="" projection_payload="" projection_root_identity=""
  local token="" extra="" tag="" encoded="" device="" inode="" manifesthex="" generation="" name="" raw=""
  local digest="" record="" pathhex="" role="" mode="" uid="" gid="" hash="" relative="" index=0 identity="" output="" result=""
  local PROJECTION_MANIFEST_UID="" PROJECTION_MANIFEST_GID="" PROJECTION_MANIFEST_RECORDS=""
  umask 077
  IFS= read -r token || [ -n "$token" ] || return 1
  if IFS= read -r extra || [ -n "$extra" ]; then return 1; fi
  IFS=: read -r tag encoded device inode manifesthex extra <<<"$token"
  [ "$tag" = dockistrate-projection-token-v2 ] && [ -z "$extra" ] || return 1
  [ "$token" = "$tag:$encoded:$device:$inode:$manifesthex" ] || return 1
  [[ "$device" =~ ^[0-9]+$ ]] && [[ "$inode" =~ ^[0-9]+$ ]] || return 1
  _projection_unhex generation "$encoded" && _projection_unhex raw "$manifesthex" || return 1
  _projection_manifest_parse "$raw" || return 1
  _secure_fs_pin_directory "$projection_root" || return 1
  [ "$SECURE_FS_PATH" != / ] || return 1
  projection_root="$SECURE_FS_PATH"
  projection_root_identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  [ "${generation%/*}" = "$projection_root" ] || return 1
  name="${generation##*/}"
  _projection_generation_name "$name" || return 1
  # Only the exact previously captured content may authorize restoring modes
  # or ownership after archive replay. No writes precede this verification.
  _projection_verify_generation "$projection_root" "$name" "$raw" false || return 1
  _projection_directory_metadata "${EUID:-$(id -u)}" "$(id -g)" 700 || return 1
  if _projection_verify_generation "$projection_root" "$name" "$raw" &&
    _projection_require_bound_root "$generation" "$device:$inode"; then
    _projection_require_bound_root "$projection_root" "$projection_root_identity" || return 1
    printf '%s' "$generation"
    return 0
  fi
  projection_stage="$(mktemp -d ./.stage-XXXXXXXXXXXX)" || return 1
  projection_stage="${projection_stage#./}"
  trap '_projection_stage_exit "$?"' EXIT
  projection_payload="$projection_root/$projection_stage/payload"
  (
    _secure_fs_enter_directory "$projection_stage" || exit 1
    _projection_directory_metadata "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" 700 || exit 1
    _secure_fs_enter_directory payload create || exit 1
    _projection_directory_metadata "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" 700
  ) || return 1
  while IFS= read -r record && [ -n "$record" ]; do
    IFS=: read -r pathhex role mode uid gid hash <<<"$record"
    _projection_unhex relative "$pathhex" || return 1
    index=$((index + 1))
    output="./$projection_stage/raw-$index"
    identity="$(_projection_source_copy "$generation" snapshot "$generation/$relative" "$output")" || return 1
    [ "$(_projection_digest <"$output")" = "$hash" ] || return 1
    _projection_make_parent "$projection_payload" "$relative" "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" || return 1
    command mv -- "$output" "./$projection_stage/payload/$relative" || return 1
    _projection_with_file "$projection_payload/$relative" _projection_file_metadata_fd "$mode" "$uid" "$gid" || return 1
  done <<<"$PROJECTION_MANIFEST_RECORDS"
  digest="$(printf '%s' "$raw" | _projection_digest)" || return 1
  result="$(_projection_publish_stage "$raw" "$digest")" || return 1
  _projection_require_bound_root "$projection_root" "$projection_root_identity" || return 1
  printf '%s' "$result"
)
