# shellcheck shell=bash

# Reuse an already pinned cwd for its descendants. The final root-binding
# checks deliberately perform a fresh absolute walk before returning a path.
function _projection_pin() {
  local target="${1:-}" policy="${2:-existing}" rest="" component="" status=0
  if [ -n "${SECURE_FS_PATH:-}" ] && [ "$target" = "$SECURE_FS_PATH" ]; then
    _secure_fs_stat_cwd
    return
  fi
  case "$target" in
  "${SECURE_FS_PATH:-}"/*)
    [ -n "${SECURE_FS_PATH:-}" ] && [ "$SECURE_FS_PATH" != / ] || { _secure_fs_pin_directory "$target" "$policy"; return; }
    rest="${target#"$SECURE_FS_PATH"/}"
    while [ -n "$rest" ]; do
      component="${rest%%/*}"
      if [ "$policy" = existing ]; then
        _secure_fs_stat_path "./$component" || status=$?
        [ "$status" -eq 0 ] || return "$status"
        [ "$SECURE_FS_TYPE" = directory ] || return 3
      fi
      _secure_fs_enter_directory "$component" "$policy" || return 1
      [ "$rest" != "$component" ] || break
      rest="${rest#*/}"
    done
    ;;
  *) _secure_fs_pin_directory "$target" "$policy" ;;
  esac
}

function _projection_with_file() (
  local path="${1:-}"
  shift || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  _projection_pin "${path%/*}" || return $?
  _secure_fs_stat_path "./${path##*/}" || return $?
  [ "$SECURE_FS_TYPE:$SECURE_FS_LINKS" = file:1 ] || return 3
  _secure_fs_with_file "./${path##*/}" "$@"
)

function _projection_identity() {
  printf '%s:%s:%s:%s:%s:%s:%s' "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" \
    "$SECURE_FS_UID" "$SECURE_FS_GID" "$SECURE_FS_MODE" "$SECURE_FS_LINKS" "$SECURE_FS_TYPE"
}

function _projection_source_fingerprint() {
  printf '%s|%s|%s|%s' "$(_projection_identity)" "$SECURE_FS_SIZE" "$SECURE_FS_MTIME" "$SECURE_FS_CTIME"
}

function _projection_directory_metadata() {
  local owner="${1:-}" group="${2:-}" mode="${3:-755}"
  _secure_fs_stat_cwd || return 1
  if [ "$SECURE_FS_UID:$SECURE_FS_GID" != "$owner:$group" ]; then
    _secure_fs_mutate_cwd chown "$owner" "$group" || return 1
  fi
  _secure_fs_mutate_cwd chmod "$mode" || return 1
  _secure_fs_stat_cwd || return 1
  [ "$SECURE_FS_UID:$SECURE_FS_GID:$SECURE_FS_MODE" = "$owner:$group:$mode" ]
}

function _projection_file_metadata_fd() {
  local mode="${1:-}" owner="${2:-}" group="${3:-}"
  _secure_fs_stat_fd8 || return 1
  if [ "$SECURE_FS_UID:$SECURE_FS_GID" != "$owner:$group" ]; then
    _secure_fs_mutate_fd8 chown "$owner" "$group" || return 1
  fi
  _secure_fs_mutate_fd8 chmod "$mode"
}

function _projection_copy_fd() {
  local identity=""
  _secure_fs_stat_fd8 || return 1
  identity="$(_projection_source_fingerprint)"
  cat <&8 >&4 || return 1
  _secure_fs_stat_fd8 || return 1
  [ "$identity" = "$(_projection_source_fingerprint)" ] || return 1
  printf '%s' "$identity"
}

function _projection_compare_fd() {
  local expected="${1:-}"
  _secure_fs_stat_fd8 || return 1
  [ "$expected" = "$(_projection_source_fingerprint)" ] || return 1
  # FD7 addresses the private raw copy. Independently opening the source and
  # comparing every byte catches changes even within coarse stat timestamps.
  cmp -s /dev/fd/7 - <&8 || return 1
  _secure_fs_stat_fd8 || return 1
  [ "$expected" = "$(_projection_source_fingerprint)" ]
}

function _projection_source_copy() (
  local root="${1:-}" role="${2:-}" source="${3:-}" raw="${4:-}"
  local server_source_policy="${5-legacy}"
  local resolved="" identity="" current="" parent_identity="" parent="" leaf=""
  case "$server_source_policy" in legacy | regular) ;; *) return 1 ;; esac
  # Managed domain serving copies are regular files. Resolve legacy issuer
  # links only; retaining the original path lets pinned traversal and the file
  # descriptor checks reject managed leaf/parent links, including later swaps.
  case "$role:$server_source_policy" in
  server-*:legacy) resolved="$(_realpath_portable "$source" && printf '.')" || return 1; resolved="${resolved%.}" ;;
  *) resolved="$source" ;;
  esac
  case "$resolved" in "$root"/*) ;; *) return 1 ;; esac
  _projection_relative "${resolved#"$root"/}" || return 1
  set -C
  exec 4>"$raw" || return 1
  set +C
  exec 7<"$raw" || return 1
  parent="${resolved%/*}" leaf="${resolved##*/}"
  _projection_pin "$parent" || return 1
  parent_identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  identity="$(_secure_fs_with_file "./$leaf" _projection_copy_fd)" || return 1
  exec 4>&-
  _secure_fs_with_file "./$leaf" _projection_compare_fd "$identity" || return 1
  exec 7<&-
  _secure_fs_stat_path "./$leaf" || return 1
  [ "$identity" = "$(_projection_source_fingerprint)" ] || return 1
  _projection_require_bound_root "$parent" "$parent_identity" || return 1
  case "$role:$server_source_policy" in
  server-*:legacy)
    current="$(_realpath_portable "$source" && printf '.')" || return 1
    [ "${current%.}" = "$resolved" ] || return 1
    ;;
  esac
  printf '%s' "${identity%%|*}"
)

function _projection_make_parent() (
  local directory="${1:-}" relative="${2:-}" owner="${3:-}" group="${4:-}" component=""
  [[ "$relative" == */* ]] || return 0
  _projection_pin "$directory" || return 1
  relative="${relative%/*}"
  while [ -n "$relative" ]; do
    component="${relative%%/*}"
    _secure_fs_enter_directory "$component" create || return 1
    _projection_directory_metadata "$owner" "$group" 755 || return 1
    [ "$relative" != "$component" ] || break
    relative="${relative#*/}"
  done
)

function _projection_verify_file_fd() {
  local mode="${1:-}" uid="${2:-}" gid="${3:-}" digest="${4:-}" metadata="${5:-true}" identity="" actual=""
  _secure_fs_stat_fd8 || return 1
  identity="$(_projection_identity)"
  if [ "$metadata" = true ]; then [ "$SECURE_FS_MODE:$SECURE_FS_UID:$SECURE_FS_GID" = "$mode:$uid:$gid" ] || return 3; fi
  actual="$(_projection_digest <&8)" || return 1
  [ "$actual" = "$digest" ] || return 3
  _secure_fs_stat_fd8 || return 1
  [ "$identity" = "$(_projection_identity)" ]
}

function _projection_inventory() (
  local prefix="${1:-}" uid="${2:-}" gid="${3:-}" metadata="${4:-true}" name="" relative=""
  shopt -s nullglob dotglob
  for name in *; do
    relative="${prefix}${name}"
    _secure_fs_stat_path "./$name" || return 1
    case "$SECURE_FS_TYPE" in
    directory)
      (
        _secure_fs_enter_directory "$name" || exit 1
        if [ "$metadata" = true ]; then [ "$SECURE_FS_MODE:$SECURE_FS_UID:$SECURE_FS_GID" = "755:$uid:$gid" ] || exit 3; fi
        printf 'd:'; printf '%s' "$relative" | _projection_hex; printf '\n'
        _projection_inventory "$relative/" "$uid" "$gid" "$metadata"
      ) || return $?
      ;;
    file)
      [ "$SECURE_FS_LINKS" -eq 1 ] || return 3
      printf 'f:'; printf '%s' "$relative" | _projection_hex; printf '\n'
      ;;
    *) return 3 ;;
    esac
  done
)

function _projection_read_manifest_fd() {
  local identity=""
  _secure_fs_stat_fd8 || return 1
  identity="$(_projection_identity)"
  cat <&8 || return 1
  _secure_fs_stat_fd8 || return 1
  [ "$identity" = "$(_projection_identity)" ]
}

function _projection_verify_generation() (
  local root="${1:-}" name="${2:-}" expected="${3:-}" metadata="${4:-true}"
  local raw="" digest="" record="" pathhex="" role="" mode="" uid="" gid="" hash="" path="" parent=""
  local wanted="" actual="" manifest_path="" generation_path=""
  local PROJECTION_MANIFEST_UID="" PROJECTION_MANIFEST_GID="" PROJECTION_MANIFEST_RECORDS=""
  _projection_generation_name "$name" || return 3
  _projection_pin "$root" || return $?
  _secure_fs_stat_path "./$name" || return $?
  [ "$SECURE_FS_TYPE" = directory ] || return 3
  _secure_fs_enter_directory "$name" || return 1
  generation_path="$SECURE_FS_PATH"
  manifest_path="$generation_path/.dockistrate-projection"
  raw="$(_projection_with_file "$manifest_path" _projection_read_manifest_fd && printf '.')" || return $?
  raw="${raw%.}"
  digest="$(printf '%s' "$raw" | _projection_digest)" || return 1
  case "$name" in "gen-$digest-"*) ;; *) return 3 ;; esac
  [ -z "$expected" ] || [ "$raw" = "$expected" ] || return 3
  _projection_manifest_parse "$raw" || return 3
  if [ "$metadata" = true ]; then
    _secure_fs_stat_cwd || return 1
    [ "$SECURE_FS_MODE:$SECURE_FS_UID:$SECURE_FS_GID" = "755:$PROJECTION_MANIFEST_UID:$PROJECTION_MANIFEST_GID" ] || return 3
  fi
  _projection_with_file "$manifest_path" _projection_verify_file_fd 600 "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" "$digest" "$metadata" || return $?
  wanted="f:$(printf '%s' .dockistrate-projection | _projection_hex)"$'\n'
  while IFS= read -r record && [ -n "$record" ]; do
    IFS=: read -r pathhex role mode uid gid hash <<<"$record"
    _projection_unhex path "$pathhex" || return 1
    _projection_with_file "$generation_path/$path" _projection_verify_file_fd "$mode" "$uid" "$gid" "$hash" "$metadata" || return $?
    wanted="${wanted}f:${pathhex}"$'\n'
    parent="$path"
    while [[ "$parent" == */* ]]; do
      parent="${parent%/*}"
      wanted="${wanted}d:$(printf '%s' "$parent" | _projection_hex)"$'\n'
    done
  done <<<"$PROJECTION_MANIFEST_RECORDS"
  wanted="$(printf '%s' "$wanted" | LC_ALL=C sort -u)" || return 1
  actual="$(_projection_inventory '' "$PROJECTION_MANIFEST_UID" "$PROJECTION_MANIFEST_GID" "$metadata" | LC_ALL=C sort)" || return $?
  [ "$actual" = "$wanted" ] || return 3
)

# Every traversal is anchored to a checked cwd. Links and non-directories are
# removed as entries; their targets are never visited, including stale caches.
function _projection_remove_tree() (
  local name="${1:-}" child="" identity="" before=""
  _secure_fs_stat_path "./$name" || return 1
  if [ "$SECURE_FS_TYPE" != directory ]; then command rm -f -- "./$name"; return; fi
  before="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  (
    _secure_fs_enter_directory "$name" || exit 1
    [ "$before" = "$SECURE_FS_DEVICE:$SECURE_FS_INODE" ] || exit 1
    shopt -s nullglob dotglob
    for child in *; do _projection_remove_tree "$child" || exit 1; done
  ) || return 1
  _secure_fs_stat_path "./$name" || return 1
  identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  [ "$SECURE_FS_TYPE" = directory ] && [ "$identity" = "$before" ] || return 1
  command rmdir -- "./$name"
)

function _projection_require_bound_root() (
  local root="${1:-}" identity="${2:-}"
  _secure_fs_pin_directory "$root" || return 1
  [ "$SECURE_FS_DEVICE:$SECURE_FS_INODE" = "$identity" ]
)
