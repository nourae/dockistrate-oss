# shellcheck shell=bash

PERMISSIONS_METADATA_HELPER_SOURCE="${BASH_SOURCE[0]}"
case "$PERMISSIONS_METADATA_HELPER_SOURCE" in
/*) ;;
*) PERMISSIONS_METADATA_HELPER_SOURCE="${PWD%/}/$PERMISSIONS_METADATA_HELPER_SOURCE" ;;
esac

if ! declare -F __dockistrate_secure_fs_loaded >/dev/null 2>&1; then
  # shellcheck source=../utils/secure_fs.sh
  source "${BASH_SOURCE[0]%/*}/../utils/secure_fs.sh"
fi

function _permissions_metadata_helper_check() {
  _secure_fs_require_capabilities
}

function _permissions_metadata_helper_run() {
  _secure_fs_run_fresh "$PERMISSIONS_METADATA_HELPER_SOURCE" _permissions_metadata_helper_mutate "$@"
}

function _permissions_metadata_selected_matches() {
  local kind="$1" device="$2" inode="$3" uid="$4" gid="$5" mode="$6" number=""
  for number in "$device" "$inode" "$uid" "$gid"; do
    case "$number" in '' | *[!0-9]*) return 1 ;; esac
  done
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  [ "${#mode}" -le 4 ] || return 1
  [ "$SECURE_FS_TYPE" = "$kind" ] && [ "$SECURE_FS_DEVICE" = "$device" ] &&
    [ "$SECURE_FS_INODE" = "$inode" ] && [ "$SECURE_FS_UID" = "$uid" ] &&
    [ "$SECURE_FS_GID" = "$gid" ] && [ "$((8#$SECURE_FS_MODE))" -eq "$((8#$mode))" ] || return 1
  case "$kind" in directory) ;; file) [ "$SECURE_FS_LINKS" = 1 ] || return 1 ;; *) return 1 ;; esac
}

function _permissions_metadata_file_mutation() {
  _permissions_metadata_selected_matches "$1" "$2" "$3" "$4" "$5" "$6" || return 1
  _secure_fs_mutate_fd8 "$7" "$8" "${9:-}"
}

function _permissions_metadata_helper_mutate() {
  (
    [ "$#" -eq 13 ] || return 1
    local root="$1" root_device="$2" root_inode="$3" path="$4" kind="$5"
    local device="$6" inode="$7" uid="$8" gid="$9" mode="${10}" operation="${11}"
    local value="${12}" group="${13}" relative="" part=""
    case "$operation" in
    chmod)
      case "$value" in '' | *[!0-7]*) return 1 ;; esac
      [ "${#value}" -le 4 ] && [ -z "$group" ] || return 1
      ;;
    chown)
      case "$value:$group" in *[!0-9:]* | :* | *:) return 1 ;; esac
      [ "${#value}" -le 10 ] && [ "${#group}" -le 10 ] &&
        [ "$((10#$value))" -lt 4294967295 ] && [ "$((10#$group))" -lt 4294967295 ] || return 1
      ;;
    *) return 1 ;;
    esac
    _secure_fs_absolute_components "$path" && [ -n "${SECURE_FS_COMPONENTS[0]-}" ] || return 1
    if [ "$root" = / ]; then
      relative="${path#/}"
    else
      case "$path" in
      "$root") relative="" ;;
      "$root"/*) relative="${path#"$root/"}" ;;
      *) return 1 ;;
      esac
    fi
    _secure_fs_pin_directory "$root" || return 1
    [ "$SECURE_FS_DEVICE" = "$root_device" ] && [ "$SECURE_FS_INODE" = "$root_inode" ] || return 1
    while [ -n "$relative" ] && [ "${relative#*/}" != "$relative" ]; do
      part="${relative%%/*}"
      relative="${relative#*/}"
      _secure_fs_enter_directory "$part" || return 1
    done
    if [ "$kind" = directory ]; then
      if [ -n "$relative" ]; then _secure_fs_enter_directory "$relative" || return 1; fi
      _permissions_metadata_selected_matches "$kind" "$device" "$inode" "$uid" "$gid" "$mode" || return 1
      _secure_fs_mutate_cwd "$operation" "$value" "$group"
    elif [ "$kind" = file ] && [ -n "$relative" ]; then
      _secure_fs_with_file "./$relative" _permissions_metadata_file_mutation \
        "$kind" "$device" "$inode" "$uid" "$gid" "$mode" "$operation" "$value" "$group"
    else
      return 1
    fi
  )
}

function _permissions_metadata_helper_mkdir_plan() {
  (
    local path="$1" part="" physical="" rest="" normalized=""
    case "$path" in /*) ;; *) return 1 ;; esac
    # mkdir historically accepts repeated/trailing separators, but not dots.
    rest="${path#/}"
    while [ -n "$rest" ]; do
      part="${rest%%/*}"
      if [ "$rest" = "$part" ]; then rest=""; else rest="${rest#*/}"; fi
      [ -z "$part" ] || normalized="$normalized/$part"
    done
    [ -n "$normalized" ] || return 1
    _secure_fs_absolute_components "$normalized" || return 1
    for part in "${SECURE_FS_COMPONENTS[@]}"; do physical="$physical/$part"; done
    printf 'root\0%s\0' "$physical"
    builtin cd -P -- / || return 1
    SECURE_FS_PATH=/
    for part in "${SECURE_FS_COMPONENTS[@]}"; do
      _secure_fs_enter_directory "$part" create || return 1
      if [ "$SECURE_FS_CREATED" = true ]; then
        printf 'created\0%s\0%s\0%s\0%s\0%s\0%s\0' "$SECURE_FS_PATH" \
          "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" "$SECURE_FS_UID" "$SECURE_FS_GID" "$SECURE_FS_MODE"
      fi
    done
    printf 'complete\0'
  )
}
