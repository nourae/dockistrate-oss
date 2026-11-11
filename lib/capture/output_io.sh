# shellcheck shell=bash

if ! declare -F _secure_fs_pin_directory >/dev/null 2>&1; then
  # shellcheck source=../utils/secure_fs.sh
  source "${BASH_SOURCE[0]%/*}/../utils/secure_fs.sh"
fi

function _capture_output_normalize() {
  local capture_path="${1:-}" capture_rest="" capture_part="" capture_alias=""
  local capture_count=0
  local -a capture_parts=()
  case "$capture_path" in /*) ;; *) return 1 ;; esac
  capture_rest="${capture_path#/}"
  while [ -n "$capture_rest" ]; do
    capture_part="${capture_rest%%/*}"
    if [ "$capture_part" = "$capture_rest" ]; then
      capture_rest=""
    else
      capture_rest="${capture_rest#*/}"
    fi
    case "$capture_part" in
    '' | .) ;;
    ..)
      if [ "$capture_count" -gt 0 ]; then
        capture_count=$((capture_count - 1))
        unset 'capture_parts[capture_count]'
      fi
      ;;
    *) capture_parts[capture_count]="$capture_part"; capture_count=$((capture_count + 1)) ;;
    esac
  done
  CAPTURE_OUTPUT_NORMALIZED_PATH=""
  for capture_part in "${capture_parts[@]-}"; do
    [ -n "$capture_part" ] || continue
    CAPTURE_OUTPUT_NORMALIZED_PATH="${CAPTURE_OUTPUT_NORMALIZED_PATH}/${capture_part}"
  done
  [ -n "$CAPTURE_OUTPUT_NORMALIZED_PATH" ] || CAPTURE_OUTPUT_NORMALIZED_PATH=/
  # These two fixed system aliases are the same exception used by the state
  # path guards. No arbitrary link participates in the directory walk.
  case "${capture_parts[0]-}" in
  tmp | var)
    capture_alias="$(readlink "/${capture_parts[0]}" 2>/dev/null || :)"
    if [ "$capture_alias" = "private/${capture_parts[0]}" ]; then
      CAPTURE_OUTPUT_NORMALIZED_PATH="/private${CAPTURE_OUTPUT_NORMALIZED_PATH}"
    fi
    ;;
  esac
}

function _capture_output_selection() {
  _capture_output_normalize "${1:-}" || return 1
  CAPTURE_OUTPUT_ROOT="$CAPTURE_OUTPUT_NORMALIZED_PATH"
  [ "$CAPTURE_OUTPUT_ROOT" != / ] || return 1
  _capture_output_normalize "${2:-}" || return 1
  CAPTURE_OUTPUT_TARGET="$CAPTURE_OUTPUT_NORMALIZED_PATH"
  case "$CAPTURE_OUTPUT_TARGET" in
  "$CAPTURE_OUTPUT_ROOT") CAPTURE_OUTPUT_RELATIVE="" ;;
  "$CAPTURE_OUTPUT_ROOT"/*) CAPTURE_OUTPUT_RELATIVE="${CAPTURE_OUTPUT_TARGET#"$CAPTURE_OUTPUT_ROOT"/}" ;;
  *)
    printf "[Error] Capture output directory '%s' must reside within '%s'.\n" "$2" "$1" >&2
    return 1
    ;;
  esac
  case "${CAPTURE_OUTPUT_RELATIVE%%/*}" in
  [tT][lL][sS]-[kK][eE][yY][sS])
    echo '[Error] tls-keys is reserved for TLS session keys; select another capture output directory.' >&2
    return 1
    ;;
  esac
}

# Called only after entering the first selected child. A subshell returns to
# its actual parent and verifies that parent against the pinned capture root.
# This also detects filesystem-equivalent Unicode names created by mkdir.
# No operation on the child or a descendant precedes this identity check.
function _capture_output_reserved_identity() {
  (
    local capture_root_device="$1" capture_root_inode="$2" capture_status=0
    builtin cd -P .. || exit 1
    _secure_fs_stat_cwd || exit 1
    [ "$SECURE_FS_TYPE" = directory ] &&
      [ "$SECURE_FS_DEVICE:$SECURE_FS_INODE" = "$capture_root_device:$capture_root_inode" ] || exit 1
    _secure_fs_stat_path ./tls-keys || capture_status=$?
    case "$capture_status" in
    0) printf '%s:%s' "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" ;;
    3) : ;; # A positively identified absent entry is allowed.
    *) exit 1 ;;
    esac
  )
}

function _capture_output_walk_relative() {
  local capture_root_device="$1" capture_root_inode="$2" capture_rest="$3"
  local capture_walk_mode="${4:-}" capture_part="" capture_first=true
  local capture_status=0 capture_reserved="" capture_child=""
  while [ -n "$capture_rest" ]; do
    capture_part="${capture_rest%%/*}"
    if [ "$capture_part" = "$capture_rest" ]; then
      capture_rest=""
    else
      capture_rest="${capture_rest#*/}"
    fi
    capture_status=0
    _secure_fs_enter_directory "$capture_part" "$capture_walk_mode" || capture_status=$?
    [ "$capture_status" -eq 0 ] || return "$capture_status"
    if [ "$capture_first" = true ]; then
      capture_child="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
      capture_reserved="$(_capture_output_reserved_identity "$capture_root_device" "$capture_root_inode")" || return 1
      if [ -n "$capture_reserved" ] && [ "$capture_reserved" = "$capture_child" ]; then
        echo '[Error] tls-keys is reserved for TLS session keys; select another capture output directory.' >&2
        return 1
      fi
      capture_first=false
    fi
  done
  _secure_fs_stat_cwd
}

function _capture_output_preflight_run() {
  _capture_output_selection "$1" "$2" || return 1
  local capture_status=0 capture_root_device="" capture_root_inode=""
  _secure_fs_pin_directory "$CAPTURE_OUTPUT_ROOT" allow-missing || capture_status=$?
  [ "$capture_status" -ne 3 ] || return 0
  [ "$capture_status" -eq 0 ] || return 1
  capture_root_device="$SECURE_FS_DEVICE" capture_root_inode="$SECURE_FS_INODE"
  _capture_output_walk_relative "$capture_root_device" "$capture_root_inode" "$CAPTURE_OUTPUT_RELATIVE" allow-missing || capture_status=$?
  [ "$capture_status" -eq 0 ] || [ "$capture_status" -eq 3 ]
}

function _capture_output_verify_run() {
  local capture_expected="$3" capture_a="" capture_b="" capture_c="" capture_d="" capture_extra=""
  case "$capture_expected" in '' | *[!0123456789:]*) return 1 ;; esac
  IFS=: read -r capture_a capture_b capture_c capture_d capture_extra <<<"$capture_expected"
  [ -n "$capture_a" ] && [ -n "$capture_b" ] && [ -n "$capture_c" ] && [ -n "$capture_d" ] &&
    [ -z "$capture_extra" ] && [ "$capture_a:$capture_b:$capture_c:$capture_d" = "$capture_expected" ] || return 1
  _capture_output_selection "$1" "$2" || return 1
  _secure_fs_pin_directory "$CAPTURE_OUTPUT_ROOT" || return 1
  [ "$SECURE_FS_DEVICE:$SECURE_FS_INODE" = "$capture_a:$capture_b" ] || return 1
  _capture_output_walk_relative "$capture_a" "$capture_b" "$CAPTURE_OUTPUT_RELATIVE" || return 1
  [ "$SECURE_FS_DEVICE:$SECURE_FS_INODE" = "$capture_c:$capture_d" ]
}

function _capture_output_prepare_run() {
  _capture_output_selection "$1" "$2" || return 1
  local capture_root="$CAPTURE_OUTPUT_ROOT" capture_target="$CAPTURE_OUTPUT_TARGET"
  local capture_relative="$CAPTURE_OUTPUT_RELATIVE" capture_root_device="" capture_root_inode="" capture_expected=""
  _secure_fs_pin_directory "$capture_root" create || return 1
  capture_root_device="$SECURE_FS_DEVICE" capture_root_inode="$SECURE_FS_INODE"
  _secure_fs_chmod_cwd 700 || return 1
  _capture_output_walk_relative "$capture_root_device" "$capture_root_inode" "$capture_relative" create || return 1
  _secure_fs_chmod_cwd 700 || return 1
  capture_expected="$capture_root_device:$capture_root_inode:$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  # Docker resolves a pathname later. Preserve the existing quiescence/lock
  # contract and reject path replacements before returning that pathname.
  (_capture_output_verify_run "$capture_root" "$capture_target" "$capture_expected") || return 1
  printf '%s\n%s' "$capture_target" "$capture_expected"
}

function _capture_output_run() {
  (
    local capture_operation="${1:-}" capture_status=0
    shift || exit 1
    case "$capture_operation:$#" in
    check:0) _secure_fs_require_capabilities || capture_status=$? ;;
    preflight:2) _capture_output_preflight_run "$@" || capture_status=$? ;;
    prepare:2) _capture_output_prepare_run "$@" || capture_status=$? ;;
    verify:3) _capture_output_verify_run "$@" || capture_status=$? ;;
    *) capture_status=1 ;;
    esac
    if [ "$capture_status" -ne 0 ]; then
      echo '[Error] Unable to access or prepare the selected capture directory safely.' >&2
      exit 1
    fi
  )
}
