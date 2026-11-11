# shellcheck shell=bash

function _projection_stage_exit() {
  local projection_exit_status="${1:-1}" projection_cleanup_status=0
  _projection_cleanup_stage || projection_cleanup_status=$?
  if [ "$projection_exit_status" -eq 0 ]; then projection_exit_status="$projection_cleanup_status"; fi
  trap - EXIT
  exit "$projection_exit_status"
}

function _projection_cleanup_stage() {
  [ -n "${projection_stage:-}" ] || return 0
  (
    [ "${SECURE_FS_PATH:-}" = "$projection_root" ] || exit 1
    _secure_fs_stat_cwd || exit 1
    [ "$SECURE_FS_DEVICE:$SECURE_FS_INODE" = "$projection_root_identity" ] || exit 1
    _projection_remove_tree "$projection_stage"
  )
}

function _projection_open_private_root() {
  local destination="${1:-}" source="${2:-}" source_identity="${3:-}"
  [ "$destination" != / ] || return 1
  case "$destination" in "$source" | "$source"/*) return 1 ;; esac
  _secure_fs_pin_directory "$destination" create || return 1
  [ "$SECURE_FS_PATH" != / ] || return 1
  case "$SECURE_FS_PATH" in "$source" | "$source"/*) return 1 ;; esac
  [ "$SECURE_FS_DEVICE:$SECURE_FS_INODE" != "$source_identity" ] || return 1
  _projection_directory_metadata "${EUID:-$(id -u)}" "$(id -g)" 700 || return 1
  _secure_fs_stat_cwd || return 1
  [ "$SECURE_FS_MODE" = 700 ]
}

function _projection_publish_stage() {
  local raw="${1:-}" digest="${2:-}" name=""
  local PROJECTION_MANIFEST_UID="" PROJECTION_MANIFEST_GID="" PROJECTION_MANIFEST_RECORDS=""
  _projection_manifest_parse "$raw" || return 1
  printf '%s' "$raw" >"./$projection_stage/payload/.dockistrate-projection" || return 1
  _projection_with_file "$projection_payload/.dockistrate-projection" _projection_file_metadata_fd 600 "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" || return 1
  (
    _projection_pin "$projection_payload" || exit 1
    _projection_directory_metadata "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" 755
  ) || return 1
  name="gen-$digest-${projection_stage#.stage-}"
  _projection_generation_name "$name" || return 1
  [ ! -e "./$name" ] && [ ! -L "./$name" ] || return 1
  command mv -- "./$projection_stage/payload" "./$name" || return 1
  _projection_verify_generation "$projection_root" "$name" "$raw" || return 1
  printf '%s' "$projection_root/$name"
}

function _projection_build() (
  local certificates="${1:-}" destination="${2:-}" certificate_root="" certificate_identity=""
  local server_source_policy="${3-legacy}"
  local projection_root="" projection_root_identity="" projection_stage="" projection_payload=""
  local owner="${EUID:-}" group="" role="" source="" relative="" complete=false index=0
  local identity="" dev="" inode="" uid="" gid="" mode="" links="" type="" raw_file="" output=""
  local pathhex="" digest="" raw="" name="" result="" records="" extra=""
  local PROJECTION_MANIFEST_UID="" PROJECTION_MANIFEST_GID="" PROJECTION_MANIFEST_RECORDS=""
  case "$server_source_policy" in legacy | regular) ;; *) return 1 ;; esac
  umask 077
  _secure_fs_pin_directory "$certificates" || return 1
  certificate_root="$SECURE_FS_PATH"
  certificate_identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  _projection_open_private_root "$destination" "$certificate_root" "$certificate_identity" || return 1
  projection_root="$SECURE_FS_PATH"
  projection_root_identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  case "$projection_root" in "$certificate_root" | "$certificate_root"/*) return 1 ;; esac
  [ "$projection_root_identity" != "$certificate_identity" ] || return 1
  [ -n "$owner" ] || owner="$(id -u)"
  group="$(id -g)" || return 1
  projection_stage="$(mktemp -d ./.stage-XXXXXXXXXXXX)" || return 1
  projection_stage="${projection_stage#./}"
  trap '_projection_stage_exit "$?"' EXIT
  projection_payload="$projection_root/$projection_stage/payload"
  (
    _secure_fs_enter_directory "$projection_stage" || exit 1
    _projection_directory_metadata "$owner" "$group" 700 || exit 1
    _secure_fs_enter_directory payload create || exit 1
    _projection_directory_metadata "$owner" "$group" 700
  ) || return 1
  : >"./$projection_stage/records" || return 1
  while IFS= read -r -d '' role; do
    if [ "$role" = complete ]; then
      complete=true
      if IFS= read -r -d '' extra || [ -n "$extra" ]; then return 1; fi
      break
    fi
    IFS= read -r -d '' source && IFS= read -r -d '' relative || return 1
    _projection_relative "$relative" || return 1
    case "$role:${relative##*/}" in
    server-cert:fullchain.pem | server-key:privkey.pem | mtls-ca:ca.crt | mtls-crl:ca.crl) ;;
    *) return 1 ;;
    esac
    index=$((index + 1))
    raw_file="./$projection_stage/raw-$index"
    output="./$projection_stage/output-$index"
    identity="$(_projection_source_copy "$certificate_root" "$role" "$source" "$raw_file" "$server_source_policy")" || return 1
    IFS=: read -r dev inode uid gid mode links type <<<"$identity"
    case "$role" in
    mtls-*)
      _projection_public_pem "$role" <"$raw_file" >"$output" || return 1
      mode=644 uid="$owner" gid="$group"
      ;;
    *)
      command mv -- "$raw_file" "$output" || return 1
      if [ "$role" = server-key ]; then mode="$(printf '%o' "$((8#$mode & 0640))")"; fi
      ;;
    esac
    digest="$(_projection_digest <"$output")" || return 1
    pathhex="$(printf '%s' "$relative" | _projection_hex)" || return 1
    printf '%s:%s:%s:%s:%s:%s\n' "$pathhex" "$role" "$mode" "$uid" "$gid" "$digest" >>"./$projection_stage/records" || return 1
    _projection_make_parent "$projection_payload" "$relative" "$owner" "$group" || return 1
    if [ -e "./$projection_stage/payload/$relative" ]; then
      cmp -s "$output" "./$projection_stage/payload/$relative" || return 1
    else
      command mv -- "$output" "./$projection_stage/payload/$relative" || return 1
      _projection_with_file "$projection_payload/$relative" _projection_file_metadata_fd "$mode" "$uid" "$gid" || return 1
    fi
  done
  [ "$complete" = true ] || return 1
  records="$(LC_ALL=C sort -u "./$projection_stage/records")" || return 1
  index=0
  while IFS= read -r extra && [ -n "$extra" ]; do index=$((index + 1)); done <<<"$records"
  raw="dockistrate-projection-v2:$owner:$group"$'\n'
  [ -z "$records" ] || raw="${raw}${records}"$'\n'
  raw="${raw}complete:$index"$'\n'
  _projection_manifest_parse "$raw" || return 1
  digest="$(printf '%s' "$raw" | _projection_digest)" || return 1
  shopt -s nullglob
  for name in "gen-$digest-"*; do
    if _projection_verify_generation "$projection_root" "$name" "$raw"; then
      _projection_require_bound_root "$certificate_root" "$certificate_identity" && _projection_require_bound_root "$projection_root" "$projection_root_identity" || return 1
      printf '%s' "$projection_root/$name"
      return 0
    fi
  done
  result="$(_projection_publish_stage "$raw" "$digest")" || return 1
  _projection_require_bound_root "$certificate_root" "$certificate_identity" && _projection_require_bound_root "$projection_root" "$projection_root_identity" || return 1
  printf '%s' "$result"
)

function _projection_operate() (
  local operation="${1:-}" root="${2:-}" generation="${3:-}" name="" identity="" candidate=""
  _secure_fs_pin_directory "$root" || return 1
  [ "$SECURE_FS_PATH" != / ] || return 1
  root="$SECURE_FS_PATH"
  identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  [ "$SECURE_FS_MODE:$SECURE_FS_UID" = "700:${EUID:-$(id -u)}" ] || return 1
  [ "${generation%/*}" = "$root" ] || return 1
  name="${generation##*/}"
  _projection_verify_generation "$root" "$name" || return 1
  if [ "$operation" = prune ]; then
    shopt -s nullglob
    for candidate in gen-*; do
      [ "$candidate" != "$name" ] || continue
      _projection_generation_name "$candidate" || continue
      _projection_remove_tree "$candidate" || return 1
    done
  fi
  _projection_require_bound_root "$root" "$identity"
)
