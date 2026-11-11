# shellcheck shell=bash

function _capture_tls_launch_session_matches_runtime() {
  local keylog="${1:-}" keylog_dir="" keylog_name="" runtime_env="" mounts=""
  local entry="" destination="" source="" writable="" mount_type="" expected_dir="" expected_library="" expected_source="" token=""
  local -a preload_paths=()
  local ssl=false libssl=false preload=false mounted=false library_mounted=false source_matches=false
  [ "${SKIP_DOCKER_CHECKS:-}" != true ] || return 0
  if ! declare -F _sslkeylog_source_fingerprint >/dev/null 2>&1; then
    # shellcheck source=lib/nginx/ensure_sslkeylog_library.sh
    source "$(dirname "${BASH_SOURCE[0]}")/../nginx/ensure_sslkeylog_library.sh" || return 1
  fi
  expected_source="$(_sslkeylog_source_fingerprint)" || return 1
  capture_tls_keylog_host_dir keylog_dir || return 1
  _capture_tls_path_leaf_name keylog_name "$keylog" "TLS key log file" || return 1
  expected_dir="$(_runtime_path_resolve_allow_missing "$keylog_dir" && printf '.')" || return 1
  expected_dir="${expected_dir%.}"
  expected_library="$(_runtime_path_resolve_allow_missing "$SSLKEYLOG_LIB_BUILD_FILE" && printf '.')" || return 1
  expected_library="${expected_library%.}"
  runtime_env="$(docker inspect --format '{{range .Config.Env}}{{if or (eq (index (split . "=") 0) "SSLKEYLOGFILE") (eq (index (split . "=") 0) "LIBSSL_SSLKEYLOGFILE") (eq (index (split . "=") 0) "LD_PRELOAD") (eq (index (split . "=") 0) "DOCKISTRATE_SSLKEYLOG_SOURCE_SHA256")}}{{println .}}{{end}}{{end}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)" || return 1
  while IFS= read -r entry; do
    case "$entry" in
    "SSLKEYLOGFILE=${NGINX_CAPTURE_KEYS_DIR}/${keylog_name}") ssl=true ;;
    "LIBSSL_SSLKEYLOGFILE=${NGINX_CAPTURE_KEYS_DIR}/${keylog_name}") libssl=true ;;
    "DOCKISTRATE_SSLKEYLOG_SOURCE_SHA256=${expected_source}") source_matches=true ;;
    DOCKISTRATE_SSLKEYLOG_SOURCE_SHA256=*)
      echo "[Error] Running Nginx uses a different TLS keylog helper version; stop and re-enable TLS decrypt capture before reusing this session." >&2
      return 1
      ;;
    SSLKEYLOGFILE=* | LIBSSL_SSLKEYLOGFILE=*) return 1 ;;
    LD_PRELOAD=*)
      preload=false
      entry="${entry#LD_PRELOAD=}"
      entry="${entry//:/ }"
      read -r -a preload_paths <<<"$entry"
      for token in "${preload_paths[@]-}"; do
        [ "$token" != "$NGINX_SSLKEYLOG_LIB_PATH" ] || preload=true
      done
      [ "$preload" = true ] || return 1
      ;;
    esac
  done <<<"$runtime_env"
  if [ "$source_matches" != true ]; then
    echo "[Error] Running Nginx has no TLS keylog helper version; stop and re-enable TLS decrypt capture before reusing this session." >&2
    return 1
  fi
  [ "$ssl" = true ] && [ "$libssl" = true ] && [ "$preload" = true ] || return 1
  mounts="$(docker inspect --format '{{range .Mounts}}{{printf "%s\t%s\t%t\t%s\n" .Destination .Source .RW .Type}}{{end}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r destination source writable mount_type; do
    [ "$mount_type" = bind ] || continue
    if [ "$destination" = "$NGINX_CAPTURE_KEYS_DIR" ] && [ "$source" = "$expected_dir" ] && [ "$writable" = true ]; then
      mounted=true
    elif [ "$destination" = "$NGINX_SSLKEYLOG_LIB_PATH" ] && [ "$source" = "$expected_library" ] && [ "$writable" = false ]; then
      library_mounted=true
    fi
  done <<<"$mounts"
  [ "$mounted" = true ] && [ "$library_mounted" = true ]
}

function _capture_tls_launch_restore_traps() {
  [ "${CAPTURE_TLS_LAUNCH_TRAPS_INSTALLED:-false}" = true ] || return 0
  if [ "${#CAPTURE_TLS_LAUNCH_DEFAULT_SIGNALS[@]}" -gt 0 ]; then
    trap - "${CAPTURE_TLS_LAUNCH_DEFAULT_SIGNALS[@]}"
  fi
  _restore_intake_restore_trap "$CAPTURE_TLS_LAUNCH_EXIT_TRAP" EXIT || return 1
  CAPTURE_TLS_LAUNCH_TRAPS_INSTALLED=false
}

function _capture_tls_launch_quiet_signals() {
  if [ "${CAPTURE_TLS_LAUNCH_TRAPS_INSTALLED:-false}" = true ] &&
    [ "${#CAPTURE_TLS_LAUNCH_DEFAULT_SIGNALS[@]}" -gt 0 ]; then
    trap '' "${CAPTURE_TLS_LAUNCH_DEFAULT_SIGNALS[@]}"
  fi
}

function _capture_tls_launch_exit_cleanup() {
  local status="${1:-1}"
  _capture_tls_launch_abort || true
  return "$status"
}

function _capture_tls_launch_install_traps() {
  local body="" action="" signal_name=""
  CAPTURE_TLS_LAUNCH_EXIT_TRAP="$(trap -p EXIT)"
  CAPTURE_TLS_LAUNCH_DEFAULT_SIGNALS=()
  if ! _restore_intake_trap_is_default "$CAPTURE_TLS_LAUNCH_EXIT_TRAP" EXIT; then
    _restore_intake_trap_action body "$CAPTURE_TLS_LAUNCH_EXIT_TRAP" EXIT || return 1
  fi
  # Preserve the trusted caller EXIT action verbatim, including its exit status.
  action='_capture_tls_launch_exit_cleanup "$?" && :'$'\n'"$body"
  trap -- "$action" EXIT
  CAPTURE_TLS_LAUNCH_TRAPS_INSTALLED=true
  for signal_name in HUP INT TERM; do
    if _restore_intake_trap_is_default "$(trap -p "$signal_name")" "$signal_name"; then
      CAPTURE_TLS_LAUNCH_DEFAULT_SIGNALS+=("$signal_name")
      case "$signal_name" in
      HUP) trap 'exit 129' HUP ;;
      INT) trap 'exit 130' INT ;;
      TERM) trap 'exit 143' TERM ;;
      esac
    fi
  done
}

# The transaction snapshots only the TLS state file. Key logs, including a new
# log from a failed attempt, are sensitive evidence and must never be rolled back.
function _capture_tls_launch_save_candidate() {
  local keylog=""
  [ -n "${CAPTURE_TLS_LAST_CREATED_KEYLOG:-}" ] || return 0
  capture_tls_keylog_file keylog || return 1
  [ "$keylog" = "$CAPTURE_TLS_LAST_CREATED_KEYLOG" ] || return 1
  _capture_tls_state_file_guard || return 1
  (
    _capture_tls_cd_guarded_runtime_dir "$CAPTURE_TLS_LAUNCH_WORKSPACE" "TLS launch recovery directory" || exit 1
    cp -pP "$CAPTURE_TLS_STATE_FILE" candidate.state || exit 1
    [ ! -L candidate.state ] && [ -f candidate.state ] || exit 1
  ) || return 1
  CAPTURE_TLS_LAUNCH_HAS_CANDIDATE=true
}

function _capture_tls_launch_restore_candidate() {
  local candidate="${CAPTURE_TLS_LAUNCH_WORKSPACE}/candidate.state" state_dir="" state_name=""
  [ "${CAPTURE_TLS_LAUNCH_HAS_CANDIDATE:-false}" = true ] || return 1
  runtime_state_path_guard "$candidate" "TLS launch recovery state" || return 1
  [ ! -L "$candidate" ] && [ -f "$candidate" ] || return 1
  _capture_tls_state_file_guard || return 1
  state_dir="$(dirname "$CAPTURE_TLS_STATE_FILE" && printf '.')" || return 1
  state_dir="${state_dir%.}"
  state_dir="${state_dir%$'\n'}"
  _capture_tls_path_leaf_name state_name "$CAPTURE_TLS_STATE_FILE" "TLS decrypt state file" || return 1
  (
    _capture_tls_cd_guarded_state_dir "$state_dir" || exit 1
    local staged=""
    staged="$(mktemp ".${state_name}.recovery.XXXXXX")" || exit 1
    if ! cp -pP "$candidate" "$staged" || [ -L "$staged" ] || [ ! -f "$staged" ] || [ -d "$state_name" ]; then
      rm -f -- "$staged"
      exit 1
    fi
    mv -f "$staged" "$state_name" || { rm -f -- "$staged"; exit 1; }
  )
}

function _capture_tls_launch_cleanup_owned_capture() {
  local cid="" cidfile="${CAPTURE_TLS_LAUNCH_WORKSPACE:-}/capture.cid"
  [ -n "${CAPTURE_TLS_LAUNCH_WORKSPACE:-}" ] || return 0
  [ "${CAPTURE_TLS_LAUNCH_CAPTURE_REMOVED:-false}" != true ] || return 0
  [ -e "$cidfile" ] || [ -L "$cidfile" ] || return 0
  runtime_state_path_guard "$cidfile" "TLS launch capture ID" || return 1
  [ ! -L "$cidfile" ] && [ -f "$cidfile" ] || return 1
  cid="$(cat "$cidfile")" || return 1
  # Docker writes the complete immutable ID, never a mutable container name.
  [[ "$cid" =~ ^[0-9a-f]{64}$ ]] || {
    echo "[Error] Invalid owned capture ID; retain recovery directory: ${CAPTURE_TLS_LAUNCH_WORKSPACE}" >&2
    return 1
  }
  if ! remove_container_and_anonymous_volumes "$cid" >/dev/null 2>&1; then
    echo "[Error] Failed to remove capture container from this attempt: ${cid}" >&2
    return 1
  fi
  CAPTURE_TLS_LAUNCH_CAPTURE_REMOVED=true
}

function _capture_tls_launch_cleanup_workspace() {
  [ -n "${CAPTURE_TLS_LAUNCH_WORKSPACE:-}" ] || return 0
  (
    _capture_tls_cd_guarded_runtime_dir "$CAPTURE_TLS_LAUNCH_WORKSPACE" "TLS launch recovery directory" || exit 1
    rm -f -- candidate.state capture.cid || exit 1
  ) || return 1
  rmdir "$CAPTURE_TLS_LAUNCH_WORKSPACE" || return 1
  CAPTURE_TLS_LAUNCH_WORKSPACE=""
}

# Called after the transaction has restored the previous state file. A failed
# recreate may leave the old container alive, so a nonzero status alone cannot
# tell us whether the running proxy still logs keys.
function _capture_tls_launch_rollback_hook() {
  local failed=false runtime_status=0 current_id="" running="" keylog_env=""
  CAPTURE_TLS_LAUNCH_ROLLBACK_CALLED=true
  _capture_tls_launch_cleanup_owned_capture || failed=true
  if [ "${CAPTURE_TLS_LAUNCH_RUNTIME_ATTEMPTED:-false}" != true ]; then
    [ "$failed" = false ]
    return $?
  fi
  if current_id="$(docker inspect --format '{{.Id}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)" &&
    [ -n "$current_id" ] && [ "$current_id" = "$CAPTURE_TLS_LAUNCH_PRIOR_PROXY_ID" ]; then
    [ "$failed" = false ]
    return $?
  fi
  recreate_nginx_container "$NGINX_IMAGE" || runtime_status=$?
  case "$runtime_status" in
  0) [ "$failed" = false ]; return $? ;;
  2)
    echo "[Error] Previous TLS mode restored, but Nginx network recovery is incomplete." >&2
    return 1
    ;;
  esac
  if running="$(docker inspect --format '{{.State.Running}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)"; then
    if [ "$running" = false ]; then
      echo "[Error] Previous TLS state restored, but the Nginx container is not running." >&2
      return 1
    fi
    if [ "$running" = true ] &&
      keylog_env="$(docker inspect --format '{{range .Config.Env}}{{if eq (index (split . "=") 0) "SSLKEYLOGFILE"}}{{println .}}{{end}}{{end}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)" &&
      [ -z "$keylog_env" ]; then
      echo "[Error] Previous TLS state restored; Nginx no longer logs keys, but runtime recovery reported a failure." >&2
      return 1
    fi
  fi
  # The attempt may still be active. Keep its state discoverable by status and
  # stop-capture instead of claiming that restored disabled state took effect.
  if ! _capture_tls_launch_restore_candidate; then
    echo "[Error] Unable to republish the attempted TLS state; retain recovery files: ${CAPTURE_TLS_LAUNCH_WORKSPACE}" >&2
  fi
  echo "[Error] TLS rollback incomplete: proxy key logging may remain active. Attempted TLS state and key logs retained for recovery: ${CAPTURE_TLS_LAUNCH_WORKSPACE}" >&2
  return 1
}

function _capture_tls_launch_abort() {
  [ "${CAPTURE_TLS_LAUNCH_ACTIVE:-false}" = true ] || return 0
  local failed=false
  _capture_tls_launch_quiet_signals
  _capture_tls_launch_cleanup_owned_capture || failed=true
  if transaction_is_active; then
    _rollback_handler_common || failed=true
  else
    # Transaction finalization may already have invoked its rollback handler.
    failed=true
  fi
  if [ "${CAPTURE_TLS_LAUNCH_ROLLBACK_CALLED:-false}" != true ]; then
    echo "[Error] TLS state recovery did not complete; proxy key logging may remain active. Retain recovery files: ${CAPTURE_TLS_LAUNCH_WORKSPACE}" >&2
    failed=true
  fi
  CAPTURE_TLS_LAUNCH_ACTIVE=false
  if [ "$failed" = false ]; then
    _capture_tls_launch_cleanup_workspace || failed=true
  fi
  _capture_tls_launch_restore_traps || failed=true
  if [ "$failed" = true ]; then
    echo "[Warn] TLS launch recovery files retained: ${CAPTURE_TLS_LAUNCH_WORKSPACE}" >&2
  fi
  [ "$failed" = false ]
}

function _capture_tls_launch_begin() {
  local context="${1:-}" enable_status=0 recreate_status=0
  CAPTURE_TLS_LAUNCH_ACTIVE=false
  CAPTURE_TLS_LAUNCH_TRAPS_INSTALLED=false
  CAPTURE_TLS_LAUNCH_WORKSPACE=""
  CAPTURE_TLS_LAUNCH_HAS_CANDIDATE=false
  CAPTURE_TLS_LAUNCH_RUNTIME_ATTEMPTED=false
  CAPTURE_TLS_LAUNCH_ROLLBACK_CALLED=false
  CAPTURE_TLS_LAUNCH_CAPTURE_REMOVED=false
  CAPTURE_TLS_LAST_CREATED_KEYLOG=""
  _capture_tls_launch_preflight || return 1
  if capture_tls_decrypt_enabled; then return 0; fi
  CAPTURE_TLS_LAUNCH_PRIOR_PROXY_ID=""
  if [ "${SKIP_DOCKER_CHECKS:-}" != true ]; then
    CAPTURE_TLS_LAUNCH_PRIOR_PROXY_ID="$(docker inspect --format '{{.Id}}' "$NGINX_CONTAINER_NAME" 2>/dev/null)" || return 1
    [ -n "$CAPTURE_TLS_LAUNCH_PRIOR_PROXY_ID" ] || return 1
  fi
  begin_transaction_return capture_tls_launch "$CAPTURE_TLS_STATE_FILE" || return 1
  CAPTURE_TLS_LAUNCH_ACTIVE=true
  rollback_pre_hook_add _capture_tls_launch_rollback_hook
  _capture_tls_launch_install_traps || { _capture_tls_launch_abort || true; return 1; }
  CAPTURE_TLS_LAUNCH_WORKSPACE="$(
    _capture_tls_cd_guarded_runtime_dir "$TMP_DIR" "TLS launch temporary directory" || exit 1
    umask 077
    mktemp -d "$TMP_DIR/capture-tls-launch.XXXXXX"
  )" || { _capture_tls_launch_abort || true; return 1; }
  enable_capture_tls_decrypt "$context" || enable_status=$?
  if [ -n "${CAPTURE_TLS_LAST_CREATED_KEYLOG:-}" ] && capture_tls_decrypt_enabled; then
    _capture_tls_launch_save_candidate || enable_status=1
  fi
  if [ "$enable_status" -ne 0 ]; then
    echo "[Error] Failed to enable TLS decrypt capture mode." >&2
    _capture_tls_launch_abort || true
    return 1
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" != true ]; then
    CAPTURE_TLS_LAUNCH_RUNTIME_ATTEMPTED=true
    recreate_nginx_container "$NGINX_IMAGE" || recreate_status=$?
    if [ "$recreate_status" -ne 0 ]; then
      echo "[Error] Failed to recreate Nginx with TLS decrypt key logging enabled." >&2
      _capture_tls_launch_abort || true
      return 1
    fi
  fi
}

function _capture_tls_launch_finish() {
  [ "${CAPTURE_TLS_LAUNCH_ACTIVE:-false}" = true ] || return 0
  _capture_tls_launch_quiet_signals
  if ! end_transaction_success; then
    _capture_tls_launch_abort || true
    return 1
  fi
  CAPTURE_TLS_LAUNCH_ACTIVE=false
  if ! _capture_tls_launch_cleanup_workspace; then
    echo "[Warn] TLS capture started, but temporary recovery files could not be removed: ${CAPTURE_TLS_LAUNCH_WORKSPACE}" >&2
  fi
  _capture_tls_launch_restore_traps || return 1
  return 0
}

function _capture_tls_launch_preflight() {
  local keylog=""
  _capture_tls_state_file_guard || return 1
  if capture_tls_decrypt_enabled; then
    capture_tls_keylog_file keylog || return 1
    [ ! -L "$keylog" ] && [ -f "$keylog" ] || {
      echo "[Error] Existing TLS decrypt session has no usable key log file." >&2
      return 1
    }
    if ! _capture_tls_launch_session_matches_runtime "$keylog"; then
      echo "[Error] Existing TLS decrypt state does not match the running proxy. Restart Nginx to apply that state, or stop-capture and retry." >&2
      return 1
    fi
    return 0
  fi
  if transaction_is_active; then
    echo "[Error] Cannot begin TLS capture setup inside an active transaction without its own recovery snapshot." >&2
    return 1
  fi
  return 0
}
