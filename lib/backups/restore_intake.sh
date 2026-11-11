# shellcheck shell=bash

# Public restore budgets never apply to trusted transaction rollback archives.
# Keep arithmetic exact in both Bash and the portable awk member counter.
function _restore_intake_decimal() {
  local raw="${1-}" label="${2:-Restore limit}" zero_ok="${3:-false}" value=""
  case "$raw" in '' | *[!0-9]*)
    echo "[Error] $label must be a positive decimal integer." >&2
    return 1
    ;;
  esac
  value="${raw#"${raw%%[!0]*}"}"
  [ -n "$value" ] || value=0
  if [ "${#value}" -gt 16 ] ||
    { [ "${#value}" -eq 16 ] && [ "$value" -gt 9007199254740990 ]; }; then
    echo "[Error] $label exceeds the supported maximum 9007199254740990." >&2
    return 1
  fi
  if [ "$value" = 0 ] && [ "$zero_ok" != true ]; then
    echo "[Error] $label must be greater than zero; raise a finite limit for a larger restore." >&2
    return 1
  fi
  printf '%s\n' "$value"
}

function _restore_intake_limits() {
  local archive_var="${1:-}" expanded_var="${2:-}" entries_var="${3:-}"
  local archive_value="" expanded_value="" entries_value=""
  require_valid_var_name "$archive_var" && require_valid_var_name "$expanded_var" &&
    require_valid_var_name "$entries_var" || return 1
  archive_value="$(_restore_intake_decimal "${RESTORE_MAX_ARCHIVE_BYTES-1073741824}" RESTORE_MAX_ARCHIVE_BYTES)" || return 1
  expanded_value="$(_restore_intake_decimal "${RESTORE_MAX_EXPANDED_BYTES-4294967296}" RESTORE_MAX_EXPANDED_BYTES)" || return 1
  entries_value="$(_restore_intake_decimal "${RESTORE_MAX_ENTRIES-20000}" RESTORE_MAX_ENTRIES)" || return 1
  printf -v "$archive_var" '%s' "$archive_value"
  printf -v "$expanded_var" '%s' "$expanded_value"
  printf -v "$entries_var" '%s' "$entries_value"
}

function _restore_intake_stat() {
  local path="${1:-}" follow="${2:-true}" record=""
  local stat_flag=""
  [ "$follow" != true ] || stat_flag="-L"
  case "$path" in -*) path="./$path" ;; esac
  # Bash 3 can run inherited ERR traps for a failed `command` builtin even
  # inside an OR-list. These read-only probes must return their status without
  # invoking the caller's transaction rollback during a normal BSD fallback.
  if record="$(trap - ERR; command stat ${stat_flag:+"$stat_flag"} -c '%d:%i:%s:%Y:%Z' -- "$path" 2>/dev/null || exit 1)"; then
    :
  elif record="$(trap - ERR; command stat ${stat_flag:+"$stat_flag"} -f '%d:%i:%z:%m:%c' "$path" 2>/dev/null || exit 1)"; then
    :
  else
    return 1
  fi
  [[ "$record" =~ ^[0-9]+:[0-9]+:[0-9]+:-?[0-9]+:-?[0-9]+$ ]] || return 1
  printf '%s\n' "$record"
}

# Inspect the actual open input descriptor. Darwin's /dev/fd entries can expose
# fdescfs metadata rather than the underlying file; both stat variants provide
# a direct stdin fstat interface that also lets us verify the descriptor type.
function _restore_intake_fstat_regular() {
  local record="" mode="" type=0
  if record="$(trap - ERR; command stat -c '%d:%i:%s:%Y:%Z:%f' -- - 2>/dev/null || exit 1)"; then
    mode="${record##*:}"
    [[ "$mode" =~ ^[0-9a-fA-F]{1,8}$ ]] || return 1
    type=$((16#$mode & 0170000))
  elif record="$(trap - ERR; command stat -f '%d:%i:%z:%m:%c:%p' 2>/dev/null || exit 1)"; then
    mode="${record##*:}"
    [[ "$mode" =~ ^[0-7]{1,8}$ ]] || return 1
    type=$((8#$mode & 0170000))
  else
    return 1
  fi
  if [ "$type" -ne 32768 ]; then
    echo "[Error] Open restore input is not a regular file." >&2
    return 1
  fi
  record="${record%:*}"
  [[ "$record" =~ ^[0-9]+:[0-9]+:[0-9]+:-?[0-9]+:-?[0-9]+$ ]] || return 1
  printf '%s\n' "$record"
}

function _restore_intake_size() {
  local record="" rest=""
  record="$(_restore_intake_stat "${1:-}")" || return 1
  rest="${record#*:}"
  rest="${rest#*:}"
  _restore_intake_decimal "${rest%%:*}" "Restore file size" true
}

# This sink consumes at most limit+1 bytes. Closing the pipe at the boundary
# stops upstream gzip/tar/find through SIGPIPE instead of draining a bomb.
function _restore_intake_bounded_stream() {
  local destination="${1:-}" limit="${2:-}" label="${3:-Restore input}" size="" status=0
  if head -c "$((limit + 1))" >"$destination"; then :; else status=$?; fi
  size="$(_restore_intake_size "$destination")" || return 1
  if [ "$size" -gt "$limit" ]; then
    echo "[Error] $label exceeds its restore limit ($limit bytes). Raise the corresponding RESTORE_MAX_* limit for an intentional larger restore." >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    echo "[Error] Failed while reading $label." >&2
    return 1
  fi
}

function _restore_intake_copy_regular() (
  local source="${1:-}" destination="${2:-}" limit="${3:-}" label="${4:-Restore input}"
  local before="" opened="" after="" follow="${5:-true}"
  [ -f "$source" ] || {
    echo "[Error] Restore input is not a regular file: $source" >&2
    return 1
  }
  before="$(_restore_intake_stat "$source" "$follow")" || return 1
  exec 3<"$source" || return 1
  opened="$(_restore_intake_fstat_regular <&3)" || return 1
  [ "$before" = "$opened" ] || {
    echo "[Error] Restore input changed while being opened: $source" >&2
    return 1
  }
  _restore_intake_bounded_stream "$destination" "$limit" "$label" <&3 || return 1
  after="$(_restore_intake_fstat_regular <&3)" || return 1
  [ "$opened" = "$after" ] && [ "$opened" = "$(_restore_intake_stat "$source" "$follow")" ] || {
    echo "[Error] Restore input changed while being copied: $source" >&2
    return 1
  }
)

function _restore_intake_checksum() {
  local archive="${1:-}" snapshot="${2:-}" workspace="${3:-}" sidecar=""
  local line="" extra_line="" expected="" checksum_name="" extra="" actual=""
  sidecar="$(_backup_archive_checksum_file "$archive")" || return 1
  if [ ! -e "$sidecar" ] && [ ! -L "$sidecar" ]; then
    echo "[Warn] No checksum sidecar found for backup archive: $archive" >&2
    return 0
  fi
  # A SHA-256 sidecar is one short record. Never read an attacker-controlled
  # unbounded line; a regular-file symlink target is snapshotted through its FD.
  if ! _restore_intake_copy_regular "$sidecar" "$workspace/checksum" 4096 "Backup checksum sidecar"; then
    echo "[Error] Unable to read a safe backup checksum sidecar: $sidecar" >&2
    return 1
  fi
  {
    IFS= read -r line || [ -n "$line" ] || return 1
    if IFS= read -r extra_line || [ -n "$extra_line" ]; then
      echo "[Error] Backup checksum sidecar must contain exactly one record." >&2
      return 1
    fi
  } <"$workspace/checksum"
  IFS=' ' read -r expected checksum_name extra <<<"$line"
  if [ -n "$extra" ] || ! [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] ||
    { [ -n "$checksum_name" ] && [ "$checksum_name" != "${archive##*/}" ]; }; then
    echo "[Error] Invalid checksum sidecar for backup archive: $sidecar" >&2
    return 1
  fi
  actual="$(_sha256_digest_file "$snapshot")" || return 1
  if [ "$actual" != "$expected" ]; then
    echo "[Error] Backup archive checksum mismatch: $archive" >&2
    return 1
  fi
}

function _restore_intake_cleanup() {
  local workspace="${1:-}"
  [ -e "$workspace" ] || [ -L "$workspace" ] || return 0
  if ! _backup_remove_private_restore_dir "$workspace"; then
    echo "[Error] Failed to remove private restore staging; retained workspace: $workspace" >&2
    return 1
  fi
}

# Bash serializes trap actions as single-quoted text with '\'' quote escapes
# (or \' for a lone quote on newer Bash). Decode those literal representations
# without interpreting backslashes, substitutions, or physical newlines.
function _restore_intake_trap_action() {
  local output_var="${1:-}" declaration="${2:-}" signal_name="${3:-}"
  local prefix="trap -- " suffix="" alternate_suffix="" encoded=""
  local escaped_quote="'\\''" quote="'"
  require_valid_var_name "$output_var" || return 1
  case "$signal_name" in
  EXIT) suffix=" EXIT" ;;
  HUP | INT | TERM) suffix=" SIG$signal_name"; alternate_suffix=" $signal_name" ;;
  *) return 1 ;;
  esac
  if [[ "$declaration" == "$prefix"*"$suffix" ]]; then
    :
  elif [ -n "$alternate_suffix" ] && [[ "$declaration" == "$prefix"*"$alternate_suffix" ]]; then
    suffix="$alternate_suffix"
  else
    return 1
  fi
  encoded="${declaration#"$prefix"}"
  encoded="${encoded%"$suffix"}"
  if [ "$encoded" = "\\'" ]; then
    encoded="$quote"
  else
    [[ "$encoded" == "$quote"*"$quote" ]] || return 1
    encoded="${encoded#"$quote"}"
    encoded="${encoded%"$quote"}"
    encoded="${encoded//"$escaped_quote"/$quote}"
  fi
  printf -v "$output_var" '%s' "$encoded"
}

function _restore_intake_trap_is_default() {
  local declaration="${1:-}" signal_name="${2:-}"
  case "$signal_name" in EXIT | HUP | INT | TERM) ;; *) return 1 ;; esac
  [ -z "$declaration" ] || [ "$declaration" = "trap -- - $signal_name" ] ||
    { [ "$signal_name" != EXIT ] && [ "$declaration" = "trap -- - SIG$signal_name" ]; }
}

function _restore_intake_restore_trap() {
  local declaration="${1:-}" signal_name="${2:-}" action=""
  if _restore_intake_trap_is_default "$declaration" "$signal_name"; then
    trap - "$signal_name"
  else
    _restore_intake_trap_action action "$declaration" "$signal_name" || return 1
    trap -- "$action" "$signal_name"
  fi
}

function _restore_intake_runtime_restore_traps() {
  if [ "${#_restore_runtime_default_signals[@]}" -gt 0 ]; then
    trap - "${_restore_runtime_default_signals[@]}"
  fi
  _restore_intake_restore_trap "$_restore_runtime_exit_trap" EXIT
}

# This runs inside the temporary EXIT trap below. The conditional invocation
# preserves the original status for the caller's EXIT action without allowing
# a failed cleanup to replace it or invoke an inherited ERR handler.
function _restore_intake_runtime_exit_cleanup() {
  local _restore_runtime_exit_status="${1:-1}"
  _restore_intake_cleanup "$_restore_runtime_workspace" || true
  _restore_intake_runtime_restore_traps
  return "$_restore_runtime_exit_status"
}

# Runtime preparation must stay in this shell: it publishes settings and
# readiness globals. Some dependency helpers terminate with exit rather than
# return, so temporarily own staged-file cleanup until this callback finishes.
# Custom/ignored signal handlers stay intact. Default termination explicitly
# exits with the conventional signal status so EXIT cleanup works even after a
# caller previously reset a signal handler to the operating-system default.
function _restore_intake_with_runtime_cleanup() {
  local _restore_runtime_workspace="${1:-}" _restore_runtime_exit_trap=""
  local _restore_runtime_exit_body="" _restore_runtime_exit_action=""
  local _restore_runtime_status=0 _restore_runtime_signal=""
  local -a _restore_runtime_default_signals=()
  shift
  _restore_runtime_exit_trap="$(trap -p EXIT)"
  if ! _restore_intake_trap_is_default "$_restore_runtime_exit_trap" EXIT; then
    _restore_intake_trap_action _restore_runtime_exit_body "$_restore_runtime_exit_trap" EXIT || return 1
  fi
  # Keep the trusted caller action at exact EOF, including its native treatment
  # of trailing backslashes and here-doc delimiters. The AND-list suppresses
  # ERR/errexit during cleanup and leaves its original status for that action.
  _restore_runtime_exit_action='_restore_intake_runtime_exit_cleanup "$?" && :'$'\n'"$_restore_runtime_exit_body"
  trap -- "$_restore_runtime_exit_action" EXIT
  for _restore_runtime_signal in HUP INT TERM; do
    if _restore_intake_trap_is_default "$(trap -p "$_restore_runtime_signal")" "$_restore_runtime_signal"; then
      _restore_runtime_default_signals+=("$_restore_runtime_signal")
      case "$_restore_runtime_signal" in
      HUP) trap 'exit 129' HUP ;;
      INT) trap 'exit 130' INT ;;
      TERM) trap 'exit 143' TERM ;;
      esac
    fi
  done
  if "$@"; then
    _restore_runtime_status=0
  else
    _restore_runtime_status=$?
  fi
  _restore_intake_runtime_restore_traps
  return "$_restore_runtime_status"
}

# The subshell owns staging cleanup and signal traps. The caller's transaction,
# ERR/EXIT handlers, shell options and live configuration stay untouched.
function _restore_intake_worker() (
  local source="${1:-}" workspace="${2:-}" archive_limit="${3:-}" expanded_limit="${4:-}" entry_limit="${5:-}"
  local result="" complete=false
  umask 077
  set -o pipefail
  # An intake error must never invoke a caller's live-state rollback hook.
  trap - ERR
  trap 'if [ "$complete" != true ]; then _restore_intake_cleanup "$workspace" || true; fi' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -d "$source" ]; then
    _restore_intake_directory "$source" "$workspace" "$expanded_limit" "$entry_limit" || return 1
    result="$workspace/directory"
  else
    _restore_intake_archive "$source" "$workspace" "$archive_limit" "$expanded_limit" "$entry_limit" || return 1
    result=""
    local entry="" count=0
    find "$workspace/extracted" -mindepth 1 -maxdepth 1 -print0 >"$workspace/top_entries" || return 1
    while IFS= read -r -d '' entry; do
      count=$((count + 1))
      [ "$count" -eq 1 ] && [ -d "$entry" ] && [ ! -L "$entry" ] || {
        echo "[Error] Backup archive must contain a single top-level directory." >&2
        return 1
      }
      result="$entry"
    done <"$workspace/top_entries"
    [ "$count" -eq 1 ] || {
      echo "[Error] Backup archive must contain a single top-level directory." >&2
      return 1
    }
  fi
  printf '%s\0' "$result" >"$workspace/result" || return 1
  complete=true
)

# These variables are local to _restore_intake_stage. The signal handler runs
# in that caller, so terminating the CLI PID also stops its intake producers.
function _restore_intake_stage_signal() {
  [ "${_restore_stage_cancel:-0}" -ne 0 ] || _restore_stage_cancel="${1:-143}"
  _restore_stage_status="$_restore_stage_cancel"
  if [ "${_restore_stage_group_owned:-false}" = true ]; then
    kill -TERM -- "-${_restore_stage_pid}" 2>/dev/null || true
  fi
}

function _restore_intake_stage_stop() {
  local started=$SECONDS
  if [ "${_restore_stage_group_owned:-false}" = true ]; then
    kill -TERM -- "-${_restore_stage_pid}" 2>/dev/null || true
    # Do not let a stalled producer make cancellation unbounded. The worker's
    # normal TERM/EXIT handlers get a short grace period for private cleanup.
    while kill -0 -- "-${_restore_stage_pid}" 2>/dev/null; do
      if [ "$((SECONDS - started))" -ge 2 ]; then
        kill -KILL -- "-${_restore_stage_pid}" 2>/dev/null || true
        break
      fi
      sleep 0.05
    done
  elif [ -n "${_restore_stage_pid:-}" ]; then
    # Before the verified group is released, the child only waits on its gate.
    # Never send a negative-PID signal when group ownership is unverified.
    kill -TERM "$_restore_stage_pid" 2>/dev/null || true
  fi
  if [ -n "${_restore_stage_pid:-}" ]; then
    wait "$_restore_stage_pid" 2>/dev/null || true
  fi
}

function _restore_intake_stage() {
  local output_var="${1:-}" source="${2:-}" workspace="${3:-}" staged_result=""
  local _restore_stage_pid="" _restore_stage_group_owned=false _restore_stage_cancel=0
  local _restore_stage_hup_trap="" _restore_stage_int_trap="" _restore_stage_term_trap=""
  local _restore_stage_monitor=false _restore_stage_status=1
  local _restore_stage_group="" _restore_stage_gate="$workspace/intake_start"
  require_valid_var_name "$output_var" || return 1
  shift 3
  _restore_stage_hup_trap="$(trap -p HUP)"
  _restore_stage_int_trap="$(trap -p INT)"
  _restore_stage_term_trap="$(trap -p TERM)"
  case "$-" in *m*) _restore_stage_monitor=true ;; esac
  trap '_restore_intake_stage_signal 129' HUP
  trap '_restore_intake_stage_signal 130' INT
  trap '_restore_intake_stage_signal 143' TERM

  if [ "$_restore_stage_cancel" -eq 0 ]; then
    # Bash 3 job control gives this one asynchronous job its own process group.
    # Disable it inside the child so all of its pipelines stay in that group;
    # restore the caller's original option immediately after launching the job.
    set -m
    (
      set +m
      trap - ERR EXIT HUP INT TERM
      local gate_started=$SECONDS
      while [ ! -f "$_restore_stage_gate" ]; do
        [ "$((SECONDS - gate_started))" -lt 5 ] || return 1
        sleep 0.02
      done
      _restore_intake_worker "$source" "$workspace" "$@"
    ) &
    _restore_stage_pid=$!
    [ "$_restore_stage_monitor" = true ] || set +m

    # Hold the worker before intake until its real PGID is verified. This also
    # makes fast successful workers and cancellation during launch race-safe.
    if _restore_stage_group="$(command ps -o pgid= -p "$_restore_stage_pid" 2>/dev/null || exit 1)"; then
      _restore_stage_group="${_restore_stage_group//[[:space:]]/}"
      if [ "$_restore_stage_group" = "$_restore_stage_pid" ]; then
        _restore_stage_group_owned=true
      fi
    fi
    if [ "$_restore_stage_group_owned" != true ]; then
      echo "[Error] Could not isolate the restore intake process group." >&2
      _restore_intake_stage_stop
    elif [ "$_restore_stage_cancel" -ne 0 ]; then
      _restore_intake_stage_stop
    elif (umask 077; : >"$_restore_stage_gate"); then
      if wait "$_restore_stage_pid"; then
        _restore_stage_status=0
      else
        _restore_stage_status=$?
      fi
      if [ "$_restore_stage_cancel" -ne 0 ] ||
        kill -0 -- "-${_restore_stage_pid}" 2>/dev/null; then
        _restore_intake_stage_stop
        [ "$_restore_stage_status" -ne 0 ] || _restore_stage_status=1
      fi
    else
      _restore_intake_stage_stop
    fi
  fi

  if [ "$_restore_stage_status" -eq 0 ]; then
    if IFS= read -r -d '' staged_result <"$workspace/result" &&
      [ -d "$staged_result" ] && [ ! -L "$staged_result" ]; then
      :
    else
      _restore_stage_status=1
    fi
  fi
  # Finish this handoff as one short boundary: a signal received while reading
  # the result still cancels and cleans it; once finalized, caller lifecycle
  # resumes. Do not let a late handler change status after the cleanup decision.
  trap '' HUP INT TERM
  if [ "$_restore_stage_cancel" -ne 0 ]; then
    _restore_stage_status="$_restore_stage_cancel"
    echo "[Error] Restore intake canceled; no backup was applied." >&2
  fi
  if [ "$_restore_stage_status" -eq 0 ]; then
    printf -v "$output_var" '%s' "$staged_result"
  else
    _restore_intake_cleanup "$workspace" || true
  fi
  _restore_intake_restore_trap "$_restore_stage_hup_trap" HUP || _restore_stage_status=1
  _restore_intake_restore_trap "$_restore_stage_int_trap" INT || _restore_stage_status=1
  _restore_intake_restore_trap "$_restore_stage_term_trap" TERM || _restore_stage_status=1
  return "$_restore_stage_status"
}
