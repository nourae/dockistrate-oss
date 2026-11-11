# shellcheck shell=bash

if ! declare -F __dockistrate_permissions_stat_loaded >/dev/null 2>&1; then
  # Support direct sourcing without requiring common.sh or runtime bootstrap.
  # shellcheck source=./stat_helpers.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stat_helpers.sh"
fi

# shellcheck source=./metadata_io.sh
source "${BASH_SOURCE[0]%/*}/metadata_io.sh"

function _permissions_metadata_require_helper() {
  _permissions_metadata_helper_check
}

function _permissions_metadata_mutate_fd() {
  local index="$1" operation="$2" value="$3" group="${4:-}"
  _permissions_metadata_helper_run \
    "$PERMISSIONS_TRANSACTION_ROOT" "$PERMISSIONS_TRANSACTION_ROOT_DEVICE" "$PERMISSIONS_TRANSACTION_ROOT_INODE" \
    "${PERMISSIONS_TXN_PATHS[$index]}" "${PERMISSIONS_TXN_TYPES[$index]}" \
    "${PERMISSIONS_TXN_DEVICES[$index]}" "${PERMISSIONS_TXN_INODES[$index]}" \
    "$PERMISSIONS_STAT_UID" "$PERMISSIONS_STAT_GID" "$PERMISSIONS_STAT_MODE" \
    "$operation" "$value" "$group"
}

# Permission repair runs in a dedicated subshell. Its transaction records only
# metadata: copying or restoring arbitrary operator files would be unsafe and
# would require working runtime directories before permission repair can begin.
function _permissions_metadata_error() {
  printf '[Error] %s\n' "$1" >&2
  return 1
}

function _permissions_metadata_mode() {
  local mode="${1:-}"
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  [ "${#mode}" -le 4 ] || return 1
  printf -v PERMISSIONS_NORMALIZED_MODE '%o' "$((8#$mode))"
}

function _permissions_metadata_resolve_directory() {
  local directory="${1:-}" resolved=""
  PERMISSIONS_PHYSICAL_DIRECTORY=""
  [ -n "$directory" ] || return 1
  case "$directory" in
  /*) ;;
  *) directory="${PWD%/}/${directory}" ;;
  esac
  # Absolute input avoids cd's '-' and option handling. The sentinel preserves
  # newlines in real directory names through command substitution; remove only
  # the sentinel and the one newline emitted by pwd itself.
  resolved="$(cd -- "$directory" && pwd -P && printf '.')" || return 1
  resolved="${resolved%.}"
  case "$resolved" in
  *$'\n') resolved="${resolved%$'\n'}" ;;
  *) return 1 ;;
  esac
  PERMISSIONS_PHYSICAL_DIRECTORY="$resolved"
}

function _permissions_metadata_read_fields() {
  local record="${1:-}" mode_format="${2:-gnu}" extra=""
  IFS=' ' read -r PERMISSIONS_STAT_DEVICE PERMISSIONS_STAT_INODE \
    PERMISSIONS_STAT_UID PERMISSIONS_STAT_GID PERMISSIONS_STAT_MODE \
    PERMISSIONS_STAT_LINKS extra <<<"$record"
  [ -z "$extra" ] || return 1
  local number=""
  for number in "$PERMISSIONS_STAT_DEVICE" "$PERMISSIONS_STAT_INODE" \
    "$PERMISSIONS_STAT_UID" "$PERMISSIONS_STAT_GID" "$PERMISSIONS_STAT_LINKS"; do
    case "$number" in '' | *[!0-9]*) return 1 ;; esac
  done
  if [ "$mode_format" = bsd ]; then
    # BSD %Lp drops set-ID/sticky bits. %p includes those bits and the file type;
    # validate the full octal field before discarding only its type bits.
    case "$PERMISSIONS_STAT_MODE" in '' | *[!0-7]*) return 1 ;; esac
    [ "${#PERMISSIONS_STAT_MODE}" -le 7 ] &&
      [ "$((8#$PERMISSIONS_STAT_MODE))" -le "$((0177777))" ] || return 1
    printf -v PERMISSIONS_STAT_MODE '%o' "$((8#$PERMISSIONS_STAT_MODE & 07777))"
  elif [ "$mode_format" = gnu ]; then
    _permissions_metadata_mode "$PERMISSIONS_STAT_MODE" || return 1
    PERMISSIONS_STAT_MODE="$PERMISSIONS_NORMALIZED_MODE"
  else
    return 1
  fi
}

function _permissions_metadata_stat() {
  local path="${1:-}" check_root="${2:-false}" record="" root_record="" mode_format=gnu
  local -a paths=("$path")
  [ ! -L "$path" ] || return 1
  if [ -d "$path" ]; then
    PERMISSIONS_STAT_TYPE=directory
  elif [ -f "$path" ]; then
    PERMISSIONS_STAT_TYPE='file'
  else
    return 1
  fi
  # One portable stat invocation checks both root and entry identity. Avoid an
  # extra external process per guard when repairing a complete checkout.
  if [ "$check_root" = true ] && [ "$path" != "$PERMISSIONS_TRANSACTION_ROOT" ]; then
    paths=("$PERMISSIONS_TRANSACTION_ROOT" "$path")
  fi
  _permissions_stat_read '%d %i %u %g %a %h' '%d %i %u %g %p %l' "${paths[@]}" || return 1
  record="$PERMISSIONS_STAT_RECORD"
  mode_format="$PERMISSIONS_STAT_DIALECT"
  if [ "$check_root" = true ]; then
    root_record="${record%%$'\n'*}"
    _permissions_metadata_read_fields "$root_record" "$mode_format" || return 1
    [ ! -L "$PERMISSIONS_TRANSACTION_ROOT" ] && [ -d "$PERMISSIONS_TRANSACTION_ROOT" ] &&
      [ "$PERMISSIONS_STAT_DEVICE" = "$PERMISSIONS_TRANSACTION_ROOT_DEVICE" ] &&
      [ "$PERMISSIONS_STAT_INODE" = "$PERMISSIONS_TRANSACTION_ROOT_INODE" ] || return 1
    if [ "$path" != "$PERMISSIONS_TRANSACTION_ROOT" ]; then
      [ "$record" != "$root_record" ] || return 1
      record="${record#*$'\n'}"
    fi
  fi
  case "$record" in *$'\n'*) return 1 ;; esac
  _permissions_metadata_read_fields "$record" "$mode_format" || return 1
  [ ! -L "$path" ] || return 1
  if [ "$PERMISSIONS_STAT_TYPE" = file ]; then
    [ -f "$path" ] && [ "$PERMISSIONS_STAT_LINKS" = 1 ] || return 1
  else
    [ -d "$path" ] || return 1
  fi
}

function _permissions_metadata_path_safe() {
  local path="${1:-}" root="${PERMISSIONS_TRANSACTION_ROOT:-}"
  local rest="" component="" current=""
  case "$path" in "$root" | "${root%/}/"*) ;; *) return 1 ;; esac
  case "$path" in /*) ;; *) return 1 ;; esac
  [ "$path" != / ] || return 0
  rest="${path#/}"
  while [ -n "$rest" ]; do
    component="${rest%%/*}"
    if [ "$rest" = "$component" ]; then
      rest=""
    else
      rest="${rest#*/}"
    fi
    case "$component" in '' | . | ..) return 1 ;; esac
    current="${current}/${component}"
    [ ! -L "$current" ] || return 1
  done
  [ "$current" = "$path" ]
}

function _permissions_metadata_guard() {
  local index="$1" path="${PERMISSIONS_TXN_PATHS[$1]}"
  _permissions_metadata_path_safe "$path" || return 1
  _permissions_metadata_stat "$path" true || return 1
  [ "$PERMISSIONS_STAT_TYPE" = "${PERMISSIONS_TXN_TYPES[$index]}" ] &&
    [ "$PERMISSIONS_STAT_DEVICE" = "${PERMISSIONS_TXN_DEVICES[$index]}" ] &&
    [ "$PERMISSIONS_STAT_INODE" = "${PERMISSIONS_TXN_INODES[$index]}" ] || return 1
  _permissions_metadata_path_safe "$path"
}

# Track only states known to belong to this repair. A pending syscall can have
# taken effect before a signal or a failing status is observed; accept its exact
# requested state, or chown's possible clearing of existing set-ID bits. Other
# changes belong to an unknown writer and must not be overwritten by rollback.
function _permissions_transaction_state_matches() {
  local index="$1" pending="${PERMISSIONS_TXN_PENDING:-}" kind="" before="" requested=""
  local current_mode="" before_mode="" intermediate=""
  PERMISSIONS_TXN_CURRENT_STATE="${PERMISSIONS_STAT_UID}:${PERMISSIONS_STAT_GID}:${PERMISSIONS_STAT_MODE}"
  [ "$PERMISSIONS_TXN_CURRENT_STATE" = "${PERMISSIONS_TXN_LAST_STATES[$index]-}" ] && return 0
  case "$pending" in "$index|"*) ;; *) return 1 ;; esac
  pending="${pending#*|}"
  kind="${pending%%|*}"
  pending="${pending#*|}"
  before="${pending%%|*}"
  requested="${pending#*|}"
  case "$requested" in *'|'*) intermediate="${requested#*|}"; requested="${requested%%|*}" ;; esac
  [ "$PERMISSIONS_TXN_CURRENT_STATE" = "$before" ] && return 0
  case "$kind" in
  chmod)
    [ "$PERMISSIONS_TXN_CURRENT_STATE" = "$requested" ] ||
      { [ -n "$intermediate" ] && [ "$PERMISSIONS_TXN_CURRENT_STATE" = "$intermediate" ]; }
    ;;
  chown)
    [ "${PERMISSIONS_TXN_CURRENT_STATE%:*}" = "${requested%:*}" ] || return 1
    current_mode="${PERMISSIONS_TXN_CURRENT_STATE##*:}"
    before_mode="${before##*:}"
    (( (8#$current_mode & 01777) == (8#$before_mode & 01777) &&
      (8#$current_mode & 06000 & ~(8#$before_mode & 06000)) == 0 ))
    ;;
  *) return 1 ;;
  esac
}

function _permissions_transaction_adopt_state() {
  local index="$1"
  _permissions_transaction_state_matches "$index" || return 1
  # Publish one complete tuple before clearing the pending operation. Either
  # side of an interruption is recoverable, including a repeated reconciliation.
  PERMISSIONS_TXN_LAST_STATES[index]="$PERMISSIONS_TXN_CURRENT_STATE"
  case "${PERMISSIONS_TXN_PENDING:-}" in "$index|"*) PERMISSIONS_TXN_PENDING="" ;; esac
  return 0
}

function _permissions_transaction_mutate() {
  local index="$1" operation="$2" value="$3" group="${4:-}"
  local before="" requested="" intermediate="" status=0
  if ! _permissions_metadata_guard "$index" || ! _permissions_transaction_adopt_state "$index"; then
    _permissions_metadata_error 'Metadata changed outside permission repair; refusing to overwrite it.'
    return 1
  fi
  before="${PERMISSIONS_TXN_LAST_STATES[$index]}"
  case "$operation" in
  chmod) requested="${PERMISSIONS_STAT_UID}:${PERMISSIONS_STAT_GID}:${value}" ;;
  chown) requested="${value}:${group}:${PERMISSIONS_STAT_MODE}" ;;
  *) return 1 ;;
  esac
  [ "$before" != "$requested" ] || return 0
  if [ "$operation" = chmod ] && [ "${PERMISSIONS_TXN_TYPES[$index]}" = file ]; then
    _secure_fs_fd_chmod_intermediate "$PERMISSIONS_STAT_MODE" "$value" "$PERMISSIONS_STAT_DIALECT" || return 1
    if [ -n "$SECURE_FS_CHMOD_INTERMEDIATE" ]; then
      intermediate="$PERMISSIONS_STAT_UID:$PERMISSIONS_STAT_GID:$SECURE_FS_CHMOD_INTERMEDIATE"
    fi
  fi
  PERMISSIONS_TXN_PENDING="${index}|${operation}|${before}|${requested}"
  # Only this planned BSD regular-file operation may adopt its exact restrictive
  # intermediate after a failure/signal. Unrelated sticky/mode changes stay unknown.
  [ -z "$intermediate" ] || PERMISSIONS_TXN_PENDING="$PERMISSIONS_TXN_PENDING|$intermediate"
  # Bind both forward repair and rollback to the inspected inode. A pathname
  # guard alone cannot prevent a symlink swap before an external chmod/chown.
  _permissions_metadata_mutate_fd "$index" "$operation" "$value" "$group" || status=$?
  if ! _permissions_metadata_guard "$index" || ! _permissions_transaction_adopt_state "$index"; then
    _permissions_metadata_error 'Permission repair observed unknown metadata changes; preserving them.'
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    _permissions_metadata_error 'Unable to change metadata during permission repair.'
    return 1
  fi
  if { [ "$operation" = chmod ] && [ "$PERMISSIONS_STAT_MODE" != "$value" ]; } ||
    { [ "$operation" = chown ] && { [ "$PERMISSIONS_STAT_UID" != "$value" ] || [ "$PERMISSIONS_STAT_GID" != "$group" ]; }; }; then
    _permissions_metadata_error 'Unable to verify metadata changes during permission repair.'
    return 1
  fi
}

function _permissions_transaction_begin() {
  local root="${1:-}" root_option="${2:-}" physical_root="" index=0 count=0 wanted_mode=""
  local wanted_uid="" wanted_gid="" original_mode="" depth="${TRANSACTION_DEPTH:-0}"
  local original_device="" original_inode="" original_uid="" original_gid=""
  if { [ "$#" -ne 1 ] && { [ "$#" -ne 2 ] || [ "$root_option" != --allow-filesystem-anchor ]; }; } ||
    [ "${PERMISSIONS_TRANSACTION_ACTIVE:-false}" = true ] ||
    [ "$depth" != 0 ]; then
    _permissions_metadata_error 'Refusing invalid or nested permission transaction.'
    return 1
  fi
  [ "${BASH_SUBSHELL:-0}" -gt 0 ] || {
    _permissions_metadata_error 'Permission transactions require a dedicated subshell.'
    return 1
  }
  [ -n "$root" ] && { [ "$root" != / ] || [ "$root_option" = --allow-filesystem-anchor ]; } &&
    [ ! -L "$root" ] && [ -d "$root" ] || {
    _permissions_metadata_error 'Refusing unsafe permission transaction root.'
    return 1
  }
  _permissions_metadata_require_helper || return 1
  _permissions_metadata_resolve_directory "$root" || return 1
  physical_root="$PERMISSIONS_PHYSICAL_DIRECTORY"
  [ "$physical_root" = "$root" ] || {
    _permissions_metadata_error 'Permission transaction root must be a physical absolute path.'
    return 1
  }
  PERMISSIONS_TRANSACTION_ROOT="$root"
  if ! _permissions_metadata_path_safe "$root" || ! _permissions_metadata_stat "$root"; then
    _permissions_metadata_error 'Unable to inspect permission transaction root.'
    return 1
  fi
  PERMISSIONS_TRANSACTION_ROOT_DEVICE="$PERMISSIONS_STAT_DEVICE"
  PERMISSIONS_TRANSACTION_ROOT_INODE="$PERMISSIONS_STAT_INODE"
  if ! declare -p PERMISSIONS_PLAN_PATHS PERMISSIONS_PLAN_MODES \
    PERMISSIONS_PLAN_UIDS PERMISSIONS_PLAN_GIDS >/dev/null 2>&1; then
    _permissions_metadata_error 'Permission transaction plan is missing.'
    return 1
  fi
  count="${#PERMISSIONS_PLAN_PATHS[@]}"
  if [ "$count" -eq 0 ] || [ "${#PERMISSIONS_PLAN_MODES[@]}" -ne "$count" ] ||
    [ "${#PERMISSIONS_PLAN_UIDS[@]}" -ne "$count" ] || [ "${#PERMISSIONS_PLAN_GIDS[@]}" -ne "$count" ]; then
    _permissions_metadata_error 'Permission transaction plan is incomplete.'
    return 1
  fi
  PERMISSIONS_TXN_PATHS=()
  PERMISSIONS_TXN_TYPES=()
  PERMISSIONS_TXN_DEVICES=()
  PERMISSIONS_TXN_INODES=()
  PERMISSIONS_TXN_OLD_MODES=()
  PERMISSIONS_TXN_OLD_UIDS=()
  PERMISSIONS_TXN_OLD_GIDS=()
  PERMISSIONS_TXN_MODES=()
  PERMISSIONS_TXN_UIDS=()
  PERMISSIONS_TXN_GIDS=()
  PERMISSIONS_TXN_APPLIED=()
  PERMISSIONS_TXN_LAST_STATES=()
  PERMISSIONS_TXN_PENDING=""
  PERMISSIONS_TXN_CURRENT_STATE=""
  for ((index = 0; index < count; index++)); do
    [ "${PERMISSIONS_PLAN_PATHS[$index]-}" != / ] || {
      _permissions_metadata_error 'Refusing to change filesystem root permissions.'
      return 1
    }
    _permissions_metadata_mode "${PERMISSIONS_PLAN_MODES[$index]-}" || {
      _permissions_metadata_error 'Invalid mode in permission transaction plan.'
      return 1
    }
    wanted_mode="$PERMISSIONS_NORMALIZED_MODE"
    wanted_uid="${PERMISSIONS_PLAN_UIDS[$index]-}"
    wanted_gid="${PERMISSIONS_PLAN_GIDS[$index]-}"
    case "$wanted_uid" in '' | *[!0-9]*)
      _permissions_metadata_error 'Invalid ownership in permission transaction plan.'
      return 1
      ;;
    esac
    case "$wanted_gid" in '' | *[!0-9]*)
      _permissions_metadata_error 'Invalid ownership in permission transaction plan.'
      return 1
      ;;
    esac
    if ! _permissions_metadata_path_safe "${PERMISSIONS_PLAN_PATHS[$index]-}" ||
      ! _permissions_metadata_stat "${PERMISSIONS_PLAN_PATHS[$index]-}"; then
      _permissions_metadata_error 'Refusing unsafe or unreadable entry in permission transaction plan.'
      return 1
    fi
    original_mode="${PERMISSIONS_PLAN_ORIGINAL_MODES[$index]-}"
    # Newly created Darwin ancestors carry their descriptor-observed identity
    # into the plan. Never adopt a replacement directory as one we created.
    original_device="${PERMISSIONS_PLAN_ORIGINAL_DEVICES[$index]-}"
    original_inode="${PERMISSIONS_PLAN_ORIGINAL_INODES[$index]-}"
    original_uid="${PERMISSIONS_PLAN_ORIGINAL_UIDS[$index]-}"
    original_gid="${PERMISSIONS_PLAN_ORIGINAL_GIDS[$index]-}"
    if [ -n "$original_device$original_inode$original_uid$original_gid" ] &&
      { [ "$original_device" != "$PERMISSIONS_STAT_DEVICE" ] ||
        [ "$original_inode" != "$PERMISSIONS_STAT_INODE" ] ||
        [ "$original_uid" != "$PERMISSIONS_STAT_UID" ] || [ "$original_gid" != "$PERMISSIONS_STAT_GID" ]; }; then
      _permissions_metadata_error 'Created directory changed while preparing the repair plan.'
      return 1
    fi
    if [ -n "$original_mode" ]; then
      _permissions_metadata_mode "$original_mode" || return 1
      original_mode="$PERMISSIONS_NORMALIZED_MODE"
      if [ "$original_mode" != "$PERMISSIONS_STAT_MODE" ]; then
        _permissions_metadata_error 'Permissions changed while preparing the repair plan.'
        return 1
      fi
    fi
    PERMISSIONS_TXN_PATHS+=("${PERMISSIONS_PLAN_PATHS[$index]}")
    PERMISSIONS_TXN_TYPES+=("$PERMISSIONS_STAT_TYPE")
    PERMISSIONS_TXN_DEVICES+=("$PERMISSIONS_STAT_DEVICE")
    PERMISSIONS_TXN_INODES+=("$PERMISSIONS_STAT_INODE")
    PERMISSIONS_TXN_OLD_MODES+=("$PERMISSIONS_STAT_MODE")
    PERMISSIONS_TXN_OLD_UIDS+=("$PERMISSIONS_STAT_UID")
    PERMISSIONS_TXN_OLD_GIDS+=("$PERMISSIONS_STAT_GID")
    PERMISSIONS_TXN_MODES+=("$wanted_mode")
    PERMISSIONS_TXN_UIDS+=("$wanted_uid")
    PERMISSIONS_TXN_GIDS+=("$wanted_gid")
    PERMISSIONS_TXN_LAST_STATES+=("${PERMISSIONS_STAT_UID}:${PERMISSIONS_STAT_GID}:${PERMISSIONS_STAT_MODE}")
  done
  # Nothing has been changed yet. Keep interruption handling local to the repair
  # subshell so the caller's transaction and signal traps remain untouched.
  PERMISSIONS_TRANSACTION_ACTIVE=true
  trap '_permissions_transaction_exit_trap "$?"' EXIT
  trap '_permissions_transaction_signal_trap 129' HUP
  trap '_permissions_transaction_signal_trap 130' INT
  trap '_permissions_transaction_signal_trap 143' TERM
}

function _permissions_transaction_apply() {
  [ "${PERMISSIONS_TRANSACTION_ACTIVE:-false}" = true ] || return 1
  local index=0 wanted_uid="" wanted_gid="" wanted_mode=""
  for ((index = 0; index < ${#PERMISSIONS_TXN_PATHS[@]}; index++)); do
    wanted_uid="${PERMISSIONS_TXN_UIDS[$index]}"
    wanted_gid="${PERMISSIONS_TXN_GIDS[$index]}"
    wanted_mode="${PERMISSIONS_TXN_MODES[$index]}"
    if ! _permissions_metadata_guard "$index" ||
      [ "$PERMISSIONS_STAT_UID" != "${PERMISSIONS_TXN_OLD_UIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_GID" != "${PERMISSIONS_TXN_OLD_GIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_MODE" != "${PERMISSIONS_TXN_OLD_MODES[$index]}" ]; then
      _permissions_metadata_error 'Permission repair entry changed after preflight.'
      return 1
    fi
    if [ "$PERMISSIONS_STAT_UID" = "$wanted_uid" ] &&
      [ "$PERMISSIONS_STAT_GID" = "$wanted_gid" ] && [ "$PERMISSIONS_STAT_MODE" = "$wanted_mode" ]; then
      continue
    fi
    # A utility can change metadata and still return failure. Record the entry
    # before the first operation so that failure is also recoverable.
    PERMISSIONS_TXN_APPLIED+=("$index")
    if [ "$PERMISSIONS_STAT_UID" != "$wanted_uid" ] || [ "$PERMISSIONS_STAT_GID" != "$wanted_gid" ]; then
      _permissions_transaction_mutate "$index" chown "$wanted_uid" "$wanted_gid" || return 1
    fi
    if [ "$PERMISSIONS_STAT_MODE" != "$wanted_mode" ]; then
      _permissions_transaction_mutate "$index" chmod "$wanted_mode" || return 1
    fi
    if ! _permissions_metadata_guard "$index" || [ "$PERMISSIONS_STAT_UID" != "$wanted_uid" ] ||
      [ "$PERMISSIONS_STAT_GID" != "$wanted_gid" ] || [ "$PERMISSIONS_STAT_MODE" != "$wanted_mode" ]; then
      _permissions_metadata_error 'Unable to verify repaired permissions.'
      return 1
    fi
  done
}

function _permissions_transaction_rollback() {
  [ "${PERMISSIONS_TRANSACTION_ACTIVE:-false}" = true ] || return 0
  # Prevent recursive rollback if another signal arrives while recovering.
  trap - EXIT
  trap '' HUP INT TERM
  local applied=0 index=0 failed=false
  for ((applied = ${#PERMISSIONS_TXN_APPLIED[@]} - 1; applied >= 0; applied--)); do
    index="${PERMISSIONS_TXN_APPLIED[$applied]}"
    if ! _permissions_metadata_guard "$index" || ! _permissions_transaction_adopt_state "$index"; then
      # A pending unknown state is scoped to this index and cannot be adopted by
      # any earlier entry that we can still safely recover.
      failed=true
      continue
    fi
    if [ "$PERMISSIONS_STAT_UID" != "${PERMISSIONS_TXN_OLD_UIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_GID" != "${PERMISSIONS_TXN_OLD_GIDS[$index]}" ]; then
      _permissions_transaction_mutate "$index" chown "${PERMISSIONS_TXN_OLD_UIDS[$index]}" \
        "${PERMISSIONS_TXN_OLD_GIDS[$index]}" || failed=true
    fi
    # Do not widen the original mode under the wrong owner after a failed chown.
    # Check again because chown can clear mode bits or another writer can act.
    if ! _permissions_metadata_guard "$index" || ! _permissions_transaction_adopt_state "$index" ||
      [ "$PERMISSIONS_STAT_UID" != "${PERMISSIONS_TXN_OLD_UIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_GID" != "${PERMISSIONS_TXN_OLD_GIDS[$index]}" ]; then
      failed=true
      continue
    fi
    if [ "$PERMISSIONS_STAT_MODE" != "${PERMISSIONS_TXN_OLD_MODES[$index]}" ]; then
      _permissions_transaction_mutate "$index" chmod "${PERMISSIONS_TXN_OLD_MODES[$index]}" || failed=true
    fi
    if ! _permissions_metadata_guard "$index" || ! _permissions_transaction_adopt_state "$index" ||
      [ "$PERMISSIONS_STAT_UID" != "${PERMISSIONS_TXN_OLD_UIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_GID" != "${PERMISSIONS_TXN_OLD_GIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_MODE" != "${PERMISSIONS_TXN_OLD_MODES[$index]}" ]; then
      failed=true
    fi
  done
  PERMISSIONS_TRANSACTION_ACTIVE=false
  trap - HUP INT TERM
  if [ "$failed" = true ]; then
    _permissions_metadata_error 'Permission repair failed and metadata rollback is incomplete; inspect the selected target.'
    return 1
  fi
  printf '[Error] Permission repair failed. Metadata changes made by this repair were rolled back.\n' >&2
}

function _permissions_transaction_end() {
  local index=0
  [ "${PERMISSIONS_TRANSACTION_ACTIVE:-false}" = true ] || return 1
  for ((index = 0; index < ${#PERMISSIONS_TXN_PATHS[@]}; index++)); do
    if ! _permissions_metadata_guard "$index" ||
      [ "$PERMISSIONS_STAT_UID" != "${PERMISSIONS_TXN_UIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_GID" != "${PERMISSIONS_TXN_GIDS[$index]}" ] ||
      [ "$PERMISSIONS_STAT_MODE" != "${PERMISSIONS_TXN_MODES[$index]}" ]; then
      _permissions_metadata_error 'Permission repair verification failed before completion.' || true
      _permissions_transaction_rollback || true
      return 1
    fi
  done
  # Before this point, a caught signal rolls back and reports failure. After
  # this point, commit must finish successfully: ignore these signals until the
  # dedicated repair subshell returns, without changing the caller's traps.
  trap '' HUP INT TERM
  trap - EXIT
  PERMISSIONS_TRANSACTION_ACTIVE=false
}

function _permissions_transaction_exit_trap() {
  local status="${1:-1}"
  if [ "${PERMISSIONS_TRANSACTION_ACTIVE:-false}" = true ]; then
    _permissions_transaction_rollback || true
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}

function _permissions_transaction_signal_trap() {
  local status="${1:-1}"
  _permissions_transaction_rollback || true
  exit "$status"
}
