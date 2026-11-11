# shellcheck shell=bash

# These helpers are used inside dedicated filesystem workers. They never use a
# pathname chmod/chown fallback. A directory's cwd or a regular file's inherited
# descriptor remains the mutation target after its original name is replaced.
SECURE_FS_STAT_STYLE=""
SECURE_FS_STAT_PATH_ENV=""

function _secure_fs_error() {
  printf '[Error] %s\n' "$1" >&2
  return 1
}

function _secure_fs_parse_stat() {
  local record="$1" style="$2" full_mode="" extra="" number="" metadata_record=""
  case "$record" in *$'\n'*) return 1 ;; esac
  IFS='|' read -r metadata_record SECURE_FS_SIZE SECURE_FS_MTIME SECURE_FS_CTIME extra <<<"$record"
  [ -z "$extra" ] && [ -n "$SECURE_FS_MTIME" ] && [ -n "$SECURE_FS_CTIME" ] &&
    [ "$record" = "$metadata_record|$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME" ] || return 1
  case "$SECURE_FS_SIZE" in '' | *[!0-9]*) return 1 ;; esac
  IFS=' ' read -r SECURE_FS_DEVICE SECURE_FS_INODE SECURE_FS_UID SECURE_FS_GID \
    full_mode SECURE_FS_LINKS extra <<<"$metadata_record"
  [ -z "$extra" ] || return 1
  for number in "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" "$SECURE_FS_UID" \
    "$SECURE_FS_GID" "$SECURE_FS_LINKS"; do
    case "$number" in '' | *[!0-9]*) return 1 ;; esac
  done
  case "$style" in
  gnu)
    case "$full_mode" in '' | *[!0-9a-fA-F]*) return 1 ;; esac
    [ "${#full_mode}" -le 6 ] || return 1
    full_mode="$((16#$full_mode))"
    ;;
  bsd)
    case "$full_mode" in '' | *[!0-7]*) return 1 ;; esac
    [ "${#full_mode}" -le 7 ] || return 1
    full_mode="$((8#$full_mode))"
    ;;
  *) return 1 ;;
  esac
  [ "$full_mode" -le "$((0177777))" ] || return 1
  printf -v SECURE_FS_MODE '%o' "$((full_mode & 07777))"
  case "$((full_mode & 0170000))" in
  "$((0100000))") SECURE_FS_TYPE=file ;;
  "$((0040000))") SECURE_FS_TYPE=directory ;;
  "$((0120000))") SECURE_FS_TYPE=symlink ;;
  *) SECURE_FS_TYPE=other ;;
  esac
}

function _secure_fs_stat_style() {
  local record=""
  if [ -n "${SECURE_FS_STAT_STYLE:-}" ] &&
    [ "${SECURE_FS_STAT_PATH_ENV:-}" = "${PATH:-}" ] &&
    ! declare -F stat >/dev/null 2>&1; then return 0; fi
  if record="$(LC_ALL=C stat -c '%d %i %u %g %f %h|%s|%y|%z' . 2>/dev/null || exit 1)" &&
    _secure_fs_parse_stat "$record" gnu; then
    SECURE_FS_STAT_STYLE=gnu
  elif record="$(LC_ALL=C stat -f '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc' . 2>/dev/null || exit 1)" &&
    _secure_fs_parse_stat "$record" bsd; then
    SECURE_FS_STAT_STYLE=bsd
  else
    return 1
  fi
  SECURE_FS_STAT_PATH_ENV="${PATH:-}"
}

# Return 3 only for the native tool's positive ENOENT diagnostic. A failed -e
# test cannot distinguish a missing entry from an inaccessible parent.
function _secure_fs_stat_path() {
  local path="$1" record="" status=0
  SECURE_FS_ERROR=""
  _secure_fs_stat_style || return 1
  case "$path" in /* | . | ./*) ;; *) path="./$path" ;; esac
  if [ "$SECURE_FS_STAT_STYLE" = gnu ]; then
    record="$(LC_ALL=C stat -c '%d %i %u %g %f %h|%s|%y|%z' -- "$path" 2>&1 || exit 1)" || status=$?
  else
    record="$(LC_ALL=C stat -f '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc' "$path" 2>&1 || exit 1)" || status=$?
  fi
  if [ "$status" -ne 0 ]; then
    SECURE_FS_ERROR="$record"
    case "$record" in
    *': No such file or directory' | *': No such file or directory (os error 2)') return 3 ;;
    *) return 1 ;;
    esac
  fi
  _secure_fs_parse_stat "$record" "$SECURE_FS_STAT_STYLE"
}

function _secure_fs_stat_cwd() {
  _secure_fs_stat_path .
}

function _secure_fs_stat_fd8() {
  local record=""
  _secure_fs_stat_style || return 1
  if [ "$SECURE_FS_STAT_STYLE" = bsd ]; then
    # Darwin /dev/fd getattr masks mode bits by the descriptor's access flags.
    # Native stat with no operands calls fstat(stdin), preserving the full mode.
    record="$(LC_ALL=C stat -f '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc' <&8 2>/dev/null || exit 1)" || return 1
  else
    record="$(LC_ALL=C stat -L -c '%d %i %u %g %f %h|%s|%y|%z' /dev/fd/8 2>/dev/null || exit 1)" || return 1
  fi
  _secure_fs_parse_stat "$record" "$SECURE_FS_STAT_STYLE"
}

function _secure_fs_require_capabilities() {
  (
    local tool="" expected=""
    for tool in stat chmod chown mkdir readlink sleep /bin/sh; do
      command -v "$tool" >/dev/null 2>&1 || {
        _secure_fs_error "Safe filesystem operations require the standard ${tool} utility."
        return 1
      }
    done
    _secure_fs_stat_cwd || return 1
    expected="$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID:$SECURE_FS_MODE:$SECURE_FS_TYPE"
    exec 8< . || return 1
    _secure_fs_stat_fd8 || return 1
    [ "$expected" = "$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID:$SECURE_FS_MODE:$SECURE_FS_TYPE" ] || return 1
  )
}

function _secure_fs_run_fresh() (
  # Bash 3 copies an active HUP/TERM trap into forked pipeline workers. Their
  # first acknowledgment signal can replay that trap, aborting rollback. Exec
  # a clean Bash at a fixed helper boundary; do not serialize caller callbacks
  # or shell state. Reset ignored signals before exec so supervision still works.
  [ "$#" -ge 2 ] || return 1
  case "$1" in /*) ;; *) return 1 ;; esac
  trap - EXIT HUP INT TERM
  BASH_ENV= ENV= exec "$BASH" --noprofile --norc -c '
    set -Eeuo pipefail
    secure_fs_fresh_source=$1
    secure_fs_fresh_entry=$2
    shift 2
    source "$secure_fs_fresh_source" || exit 1
    declare -F "$secure_fs_fresh_entry" >/dev/null 2>&1 || exit 1
    "$secure_fs_fresh_entry" "$@"
  ' _ "$@"
)

function _secure_fs_enter_directory() {
  local name="$1" policy="${2:-existing}" expected_device="" expected_inode="" status=0
  local parent_path="${SECURE_FS_PATH:-}"
  SECURE_FS_CREATED=false
  case "$name" in '' | . | .. | */*) return 1 ;; esac
  case "$policy" in existing | create | allow-missing) ;; *) return 1 ;; esac
  _secure_fs_stat_path "./$name" || status=$?
  if [ "$status" -eq 3 ]; then
    [ "$policy" != allow-missing ] || return 3
    [ "$policy" = create ] || return 1
    if mkdir -m 700 "./$name" 2>/dev/null; then SECURE_FS_CREATED=true; fi
    _secure_fs_stat_path "./$name" || return 1
  elif [ "$status" -ne 0 ]; then
    return 1
  fi
  [ "$SECURE_FS_TYPE" = directory ] || return 1
  expected_device="$SECURE_FS_DEVICE"
  expected_inode="$SECURE_FS_INODE"
  builtin cd -P -- "./$name" || return 1
  _secure_fs_stat_cwd || return 1
  [ "$SECURE_FS_TYPE" = directory ] && [ "$SECURE_FS_DEVICE" = "$expected_device" ] &&
    [ "$SECURE_FS_INODE" = "$expected_inode" ] || return 1
  SECURE_FS_PATH="${parent_path%/}/$name"
}

function _secure_fs_absolute_components() {
  local path="$1" rest="" part="" alias=""
  case "$path" in /*) ;; *) return 1 ;; esac
  SECURE_FS_COMPONENTS=()
  [ "$path" != / ] || return 0
  rest="${path#/}"
  while :; do
    part="${rest%%/*}"
    # Repeated separators do not name another object. Keep rejecting dot
    # traversal and validate each actual directory component independently.
    case "$part" in . | ..) return 1 ;; esac
    [ -z "$part" ] || SECURE_FS_COMPONENTS+=("$part")
    [ "$rest" != "$part" ] || break
    rest="${rest#*/}"
  done
  # Only the two documented system aliases are accepted, never an arbitrary
  # link with a convenient physical spelling.
  case "${SECURE_FS_COMPONENTS[0]-}" in
  tmp | var)
    alias="$(readlink "/${SECURE_FS_COMPONENTS[0]}" 2>/dev/null || true)"
    if [ "$alias" = "private/${SECURE_FS_COMPONENTS[0]}" ]; then
      SECURE_FS_COMPONENTS=(private "${SECURE_FS_COMPONENTS[@]}")
    fi
    ;;
  esac
}

function _secure_fs_pin_directory() {
  local path="$1" policy="${2:-existing}" part="" status=0
  _secure_fs_absolute_components "$path" || return 1
  builtin cd -P -- / || return 1
  SECURE_FS_PATH=/
  SECURE_FS_CREATED=false
  _secure_fs_stat_cwd || return 1
  for part in "${SECURE_FS_COMPONENTS[@]+"${SECURE_FS_COMPONENTS[@]}"}"; do
    _secure_fs_enter_directory "$part" "$policy" || { status=$?; return "$status"; }
  done
}

function _secure_fs_fd_chmod_intermediate() {
  local before="$1" requested="$2" style="$3"
  SECURE_FS_CHMOD_INTERMEDIATE=""
  case "$before:$requested" in *[!0-7:]* | :* | *:) return 1 ;; esac
  [ "${#before}" -le 4 ] && [ "${#requested}" -le 4 ] || return 1
  # Darwin chmod skips its syscall if the target equals /dev/fd's masked
  # readonly mode. Toggle only sticky while retaining existing read bits; no
  # write, execute or set-ID access is introduced, and rollback can reopen it.
  if [ "$style" = bsd ] && [ "$((8#$before))" -ne "$((8#$requested))" ] &&
    [ "$((8#$before & 07444))" -eq "$((8#$requested))" ]; then
    printf -v SECURE_FS_CHMOD_INTERMEDIATE '%o' "$(( (8#$before & 0444) | ((8#$requested ^ 01000) & 01000) ))"
  fi
}

function _secure_fs_mutate_fd8() {
  local operation="$1" value="$2" group="${3:-}" exact_mode="" identity="" intermediate=""
  case "$operation" in
  chmod)
    case "$value" in '' | *[!0-7]*) return 1 ;; esac
    [ "${#value}" -le 4 ] && [ -z "$group" ] || return 1
    printf -v exact_mode '%05o' "$((8#$value))"
    _secure_fs_stat_fd8 || return 1
    [ "$SECURE_FS_TYPE" = file ] && [ "$SECURE_FS_LINKS" = 1 ] || return 1
    identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID"
    _secure_fs_fd_chmod_intermediate "$SECURE_FS_MODE" "$value" "$SECURE_FS_STAT_STYLE" || return 1
    if [ -n "$SECURE_FS_CHMOD_INTERMEDIATE" ]; then
      intermediate="$SECURE_FS_CHMOD_INTERMEDIATE"
      printf -v exact_mode '%05o' "$((8#$intermediate))"
      chmod "$exact_mode" /dev/fd/8 || return 1
      _secure_fs_stat_fd8 && [ "$SECURE_FS_TYPE" = file ] && [ "$SECURE_FS_LINKS" = 1 ] &&
        [ "$SECURE_FS_MODE" = "$intermediate" ] &&
        [ "$identity" = "$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID" ] || return 1
      printf -v exact_mode '%05o' "$((8#$value))"
    fi
    chmod "$exact_mode" /dev/fd/8 || return 1
    _secure_fs_stat_fd8 && [ "$SECURE_FS_TYPE" = file ] && [ "$SECURE_FS_LINKS" = 1 ] &&
      [ "$((8#$SECURE_FS_MODE))" -eq "$((8#$value))" ] &&
      [ "$identity" = "$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID" ]
    ;;
  chown)
    case "$value:$group" in *[!0-9:]* | :* | *:) return 1 ;; esac
    chown "$value:$group" /dev/fd/8 || return 1
    _secure_fs_stat_fd8 && [ "$SECURE_FS_UID" = "$value" ] && [ "$SECURE_FS_GID" = "$group" ]
    ;;
  *) return 1 ;;
  esac
}

function _secure_fs_mutate_cwd() {
  local operation="$1" value="$2" group="${3:-}" exact_mode=""
  case "$operation" in
  chmod)
    case "$value" in '' | *[!0-7]*) return 1 ;; esac
    [ "${#value}" -le 4 ] && [ -z "$group" ] || return 1
    # GNU chmod preserves directory set-ID bits for ordinary numeric modes.
    # Five octal digits request the exact mode, matching fchmod on BSD too.
    printf -v exact_mode '%05o' "$((8#$value))"
    chmod "$exact_mode" . || return 1
    _secure_fs_stat_cwd && [ "$((8#$SECURE_FS_MODE))" -eq "$((8#$value))" ]
    ;;
  chown)
    case "$value:$group" in *[!0-9:]* | :* | *:) return 1 ;; esac
    chown "$value:$group" . || return 1
    _secure_fs_stat_cwd && [ "$SECURE_FS_UID" = "$value" ] && [ "$SECURE_FS_GID" = "$group" ]
    ;;
  *) return 1 ;;
  esac
}

function _secure_fs_chmod_cwd() {
  _secure_fs_mutate_cwd chmod "$1"
}

function __dockistrate_secure_fs_loaded() { :; }
# shellcheck shell=bash

# A foreground pipeline is deliberate: Bash 3 cannot wait for a process-
# substitution PID. The invoking shell reaps both stages of this pipeline.
# READY/USR1 prevents a timed-out open from beginning a late mutation.
function _secure_fs_file_worker() {
  local path="$1" callback="$2" secure_fs_worker_ack=false status=0 before="" parent=""
  shift 2
  trap - EXIT HUP INT TERM
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  trap 'secure_fs_worker_ack=true' USR1
  /bin/sh -c 'printf "PID %s\n" "$PPID"' >&9 || return 1
  case "$path" in
  /*)
    parent="${path%/*}"
    [ -n "$parent" ] || parent=/
    if ! _secure_fs_pin_directory "$parent"; then _secure_fs_worker_done 1; return 1; fi
    path="./${path##*/}"
    ;;
  ./*) path="${path#./}"; case "$path" in '' | . | .. | */*) _secure_fs_worker_done 1; return 1 ;; esac; path="./$path" ;;
  *) case "$path" in '' | . | .. | */*) _secure_fs_worker_done 1; return 1 ;; esac; path="./$path" ;;
  esac
  if ! _secure_fs_stat_path "$path" || [ "$SECURE_FS_TYPE" != file ] ||
    [ "$SECURE_FS_LINKS" != 1 ]; then
    _secure_fs_worker_done 1
    return 1
  fi
  before="$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID:$SECURE_FS_MODE:$SECURE_FS_LINKS|$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME"
  if ! exec 8< "$path"; then
    _secure_fs_worker_done 1
    _secure_fs_error 'Unable to open the selected inode safely; use sufficient privileges (sudo).'
    return 1
  fi
  printf 'READY\n' >&9 || return 1
  while [ "$secure_fs_worker_ack" != true ]; do sleep 0.01; done
  secure_fs_worker_ack=false
  if ! _secure_fs_stat_fd8 || [ "$SECURE_FS_TYPE" != file ] ||
    [ "$before" != "$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID:$SECURE_FS_MODE:$SECURE_FS_LINKS|$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME" ]; then
    _secure_fs_worker_done 1
    return 1
  fi
  "$callback" "$@" || status=$?
  _secure_fs_worker_done "$status" || return 1
  return "$status"
}

function _secure_fs_worker_done() {
  printf 'DONE %s\n' "$1" >&9 || return 1
  # Do not exit while the supervisor still owns a signalable PID. The second
  # acknowledgment transfers ownership before the worker can be reaped.
  while [ "$secure_fs_worker_ack" != true ]; do sleep 0.01; done
}

function _secure_fs_acknowledge_done() {
  local finished_pid="$secure_fs_worker_pid" status=0
  # Keep this short transfer indivisible with respect to our cleanup handlers.
  trap '' HUP INT TERM
  secure_fs_worker_pid=""
  kill -USR1 "$finished_pid" 2>/dev/null || status=$?
  trap '_secure_fs_supervise_cleanup; exit 143' TERM
  trap '_secure_fs_supervise_cleanup; exit 130' INT
  trap '_secure_fs_supervise_cleanup; exit 129' HUP
  return "$status"
}

function _secure_fs_supervise_body() {
  local line="" result=""
  IFS= read -r -t 5 line || return 1
  case "$line" in 'PID '*) secure_fs_worker_pid="${line#PID }" ;; *) return 1 ;; esac
  case "$secure_fs_worker_pid" in '' | *[!0-9]*) secure_fs_worker_pid=""; return 1 ;; esac
  [ "$secure_fs_worker_pid" -gt 1 ] || { secure_fs_worker_pid=""; return 1; }
  local read_status=0
  IFS= read -r -t 5 line || read_status=$?
  if [ "$read_status" -ne 0 ]; then
    # Bash 3 reports both timeout and EOF as status 1. Every expected worker
    # outcome remains alive for DONE acknowledgment, so failed reads still own
    # this worker until cleanup signals it and the pipeline parent reaps it.
    _secure_fs_error 'Timed out opening the selected inode safely.'
    return 1
  fi
  case "$line" in
  READY) ;;
  'DONE 1') _secure_fs_acknowledge_done || return 1; return 1 ;;
  *) return 1 ;;
  esac
  kill -USR1 "$secure_fs_worker_pid" || return 1
  IFS= read -r line || { secure_fs_worker_pid=""; return 1; }
  case "$line" in 'DONE '*) result="${line#DONE }" ;; *) return 1 ;; esac
  case "$result" in '' | *[!0-9]*) return 1 ;; esac
  [ "${#result}" -le 3 ] && [ "$result" -le 255 ] || return 1
  _secure_fs_acknowledge_done || return 1
  return "$result"
}

function _secure_fs_supervise_cleanup() {
  if [ -n "${secure_fs_worker_pid:-}" ]; then
    kill -TERM "$secure_fs_worker_pid" 2>/dev/null || true
    secure_fs_worker_pid=""
  fi
}

function _secure_fs_file_supervisor() {
  local secure_fs_worker_pid="" status=0
  trap '_secure_fs_supervise_cleanup' EXIT
  trap '_secure_fs_supervise_cleanup; exit 143' TERM
  trap '_secure_fs_supervise_cleanup; exit 130' INT
  trap '_secure_fs_supervise_cleanup; exit 129' HUP
  _secure_fs_supervise_body || status=$?
  # Bash 3 does not run an EXIT trap when a pipeline function simply returns.
  _secure_fs_supervise_cleanup
  trap - EXIT HUP INT TERM
  return "$status"
}

function _secure_fs_with_file() {
  (
    # File bytes and callback output go directly to the original stdout, never
    # through the supervisor's protocol or shell variables.
    exec 6>&1
    set -o pipefail
    _secure_fs_file_worker "$@" 9>&1 1>&6 | _secure_fs_file_supervisor
  )
}
