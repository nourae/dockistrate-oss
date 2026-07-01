# shellcheck shell=bash

function _capture_is_true() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
  1 | true | yes | on)
    return 0
    ;;
  esac
  return 1
}

function _capture_context_flat() {
  local context="${1:-}"
  context="${context//$'\r'/ }"
  context="${context//$'\n'/ }"
  context="${context//$'\t'/ }"
  while [[ "$context" == *"  "* ]]; do
    context="${context//  / }"
  done
  context="${context# }"
  context="${context% }"
  context="${context//\"/\\\"}"
  printf '%s' "$context"
}

function acknowledge_tls_decrypt_capture() {
  local context="${1:-}"
  local flat_context=""
  flat_context="$(_capture_context_flat "$context")"
  echo "[Warn] TLS decrypt capture explicitly enabled: ${flat_context}" >&2
  audit_log "tls_decrypt acknowledged context=\"${flat_context}\""
}

function capture_tls_keylog_host_dir() {
  local __var="$1"
  require_valid_var_name "$__var" || return 1
  printf -v "$__var" '%s' "${CAPTURE_DIR%/}/tls-keys"
}

function _capture_tls_state_file_guard() {
  if ! declare -F runtime_state_path_guard >/dev/null 2>&1; then
    echo "[Error] Runtime path guard unavailable for TLS decrypt state validation." >&2
    return 1
  fi
  runtime_state_path_guard "$CAPTURE_TLS_STATE_FILE" "TLS decrypt state file" || return 1
}

function _capture_tls_keylog_path_guard() {
  local keylog_file="${1:-}" keylog_host_dir="" keylog_root="" keylog_path=""
  local keylog_root_cmp="" keylog_path_cmp=""
  local keylog_root_len=0

  [ -n "$keylog_file" ] || {
    echo "[Error] TLS decrypt state does not contain a key log file path." >&2
    return 1
  }

  capture_tls_keylog_host_dir keylog_host_dir || return 1
  keylog_root="${keylog_host_dir%/}"
  keylog_path="${keylog_file%/}"

  if ! declare -F runtime_state_path_guard >/dev/null 2>&1; then
    echo "[Error] Runtime path guard unavailable for TLS key log validation." >&2
    return 1
  fi
  runtime_state_path_guard "$keylog_root" "TLS key log directory" || return 1
  runtime_state_path_guard "$keylog_path" "TLS key log file" || return 1

  if ! declare -F _runtime_path_resolve_allow_missing >/dev/null 2>&1; then
    echo "[Error] Runtime path resolver unavailable for TLS key log validation." >&2
    return 1
  fi
  keylog_root_cmp="$(_runtime_path_resolve_allow_missing "$keylog_root")" || {
    echo "[Error] Unable to resolve TLS key log directory: ${keylog_root}" >&2
    return 1
  }
  keylog_path_cmp="$(_runtime_path_resolve_allow_missing "$keylog_path")" || {
    echo "[Error] Unable to resolve TLS key log file: ${keylog_path}" >&2
    return 1
  }

  keylog_root_len=${#keylog_root_cmp}
  if [ "${keylog_path_cmp:0:keylog_root_len}" = "$keylog_root_cmp" ] &&
    [ "${keylog_path_cmp:$keylog_root_len:1}" = "/" ]; then
    return 0
  fi

  echo "[Error] Refusing to use TLS key log file outside capture key directory: ${keylog_file}" >&2
  return 1
}

function _capture_tls_path_leaf_name() {
  local __var="${1:-}" path="${2:-}" label="${3:-runtime file}" leaf=""
  require_valid_var_name "$__var" || return 1
  path="${path%/}"
  leaf="${path##*/}"
  case "$leaf" in
  '' | . | .. | */*)
    echo "[Error] Refusing to use unsafe ${label} name: ${path}" >&2
    return 1
    ;;
  esac
  printf -v "$__var" '%s' "$leaf"
}

function _capture_tls_keylog_dir_guard() {
  local keylog_dir="${1:-}" expected_dir="" keylog_dir_cmp="" expected_dir_cmp=""
  [ -n "$keylog_dir" ] || {
    echo "[Error] Runtime directory guard requires a path for TLS key log directory." >&2
    return 1
  }
  if ! declare -F runtime_state_path_guard >/dev/null 2>&1; then
    echo "[Error] Runtime path guard unavailable for TLS key log directory validation." >&2
    return 1
  fi
  if ! declare -F _runtime_path_resolve_allow_missing >/dev/null 2>&1; then
    echo "[Error] Runtime path resolver unavailable for TLS key log directory validation." >&2
    return 1
  fi

  capture_tls_keylog_host_dir expected_dir || return 1
  runtime_state_path_guard "$keylog_dir" "TLS key log directory" || return 1
  runtime_state_path_guard "$expected_dir" "TLS key log directory" || return 1
  keylog_dir_cmp="$(_runtime_path_resolve_allow_missing "$keylog_dir")" || {
    echo "[Error] Unable to resolve TLS key log directory: ${keylog_dir}" >&2
    return 1
  }
  expected_dir_cmp="$(_runtime_path_resolve_allow_missing "$expected_dir")" || {
    echo "[Error] Unable to resolve TLS key log directory: ${expected_dir}" >&2
    return 1
  }

  [ "$keylog_dir_cmp" = "$expected_dir_cmp" ] || {
    echo "[Error] Refusing to use non-canonical TLS key log directory: ${keylog_dir}" >&2
    return 1
  }
}

function _capture_tls_cd_guarded_runtime_dir() {
  local dir="${1:-}" label="${2:-runtime directory}" actual="" rechecked="" dir_abs=""
  [ -n "$dir" ] || {
    echo "[Error] Runtime directory guard requires a path for ${label}." >&2
    return 1
  }
  if ! declare -F runtime_state_path_guard >/dev/null 2>&1; then
    echo "[Error] Runtime path guard unavailable for ${label} validation." >&2
    return 1
  fi
  if ! declare -F _runtime_path_resolve_allow_missing >/dev/null 2>&1; then
    echo "[Error] Runtime path resolver unavailable for ${label} validation." >&2
    return 1
  fi
  if ! declare -F _runtime_path_to_absolute_lexical >/dev/null 2>&1; then
    echo "[Error] Runtime path resolver unavailable for ${label} validation." >&2
    return 1
  fi

  dir_abs="$(_runtime_path_to_absolute_lexical "$dir")" || {
    echo "[Error] Unable to resolve ${label}: ${dir}" >&2
    return 1
  }
  runtime_state_path_guard "$dir_abs" "$label" || return 1
  [ -d "$dir_abs" ] || {
    echo "[Error] ${label} does not exist: ${dir}" >&2
    return 1
  }
  if [ -L "$dir_abs" ]; then
    echo "[Error] Refusing to use symlinked ${label}: ${dir}" >&2
    return 1
  fi

  cd -P "$dir_abs" 2>/dev/null || {
    echo "[Error] Unable to enter ${label}: ${dir}" >&2
    return 1
  }
  if [ -L "$dir_abs" ]; then
    echo "[Error] Refusing to use symlinked ${label}: ${dir}" >&2
    return 1
  fi
  actual="$(pwd -P)" || return 1
  runtime_state_path_guard "$actual" "$label" || return 1
  rechecked="$(_runtime_path_resolve_allow_missing "$dir_abs")" || {
    echo "[Error] Unable to resolve ${label}: ${dir}" >&2
    return 1
  }
  if [ "$actual" != "$rechecked" ]; then
    echo "[Error] Refusing ${label} swap during TLS decrypt mutation: ${dir}" >&2
    return 1
  fi
}

function _capture_tls_cd_guarded_keylog_dir() {
  _capture_tls_cd_guarded_runtime_dir "${1:-}" "TLS key log directory"
}

function _capture_tls_cd_guarded_state_dir() {
  _capture_tls_cd_guarded_runtime_dir "${1:-}" "TLS decrypt state directory"
}

function capture_tls_prepare_keylog_for_mount() {
  local __keylog_name_var="${1:-}" keylog_dir="${2:-}" keylog_file="${3:-}"
  local keylog_dir_mode="${4:-700}" keylog_file_mode="${5:-600}" keylog_name=""
  require_valid_var_name "$__keylog_name_var" || return 1
  _capture_tls_path_leaf_name keylog_name "$keylog_file" "TLS key log file" || return 1
  _capture_tls_keylog_path_guard "$keylog_file" || return 1
  _capture_tls_keylog_dir_guard "$keylog_dir" || return 1
  mkdir -p "$keylog_dir" || return 1
  _capture_tls_keylog_dir_guard "$keylog_dir" || return 1
  _capture_tls_keylog_path_guard "$keylog_file" || return 1
  (
    _capture_tls_cd_guarded_keylog_dir "$keylog_dir" || exit 1
    chmod "$keylog_dir_mode" . 2>/dev/null || true
    if [ -f "$keylog_name" ]; then
      chmod "$keylog_file_mode" "$keylog_name" 2>/dev/null || true
    fi
  ) || return 1
  printf -v "$__keylog_name_var" '%s' "$keylog_name"
}

function capture_tls_decrypt_enabled() {
  _capture_tls_state_file_guard || return 1
  [ -f "$CAPTURE_TLS_STATE_FILE" ] || return 1
  local enabled
  enabled="$(awk -F'=' '$1=="enabled"{print $2; exit}' "$CAPTURE_TLS_STATE_FILE" 2>/dev/null || true)"
  _capture_is_true "$enabled"
}

function capture_tls_decrypt_state_exists() {
  _capture_tls_state_file_guard || return 1
  [ -f "$CAPTURE_TLS_STATE_FILE" ] || return 1
}

function capture_tls_keylog_file() {
  local __var="$1"
  require_valid_var_name "$__var" || return 1
  [ -f "$CAPTURE_TLS_STATE_FILE" ] || return 1
  local resolved_keylog_file=""
  _capture_tls_state_file_guard || return 1
  resolved_keylog_file="$(awk -F'=' '$1=="keylog_file"{sub(/^keylog_file=/,""); print; exit}' "$CAPTURE_TLS_STATE_FILE" 2>/dev/null || true)"
  _capture_tls_keylog_path_guard "$resolved_keylog_file" || return 1
  printf -v "$__var" '%s' "$resolved_keylog_file"
}

function capture_tls_keylog_permissions() {
  local __dir_mode_var="$1" __file_mode_var="$2"
  require_valid_var_name "$__dir_mode_var" || return 1
  require_valid_var_name "$__file_mode_var" || return 1

  printf -v "$__dir_mode_var" '%s' "700"
  printf -v "$__file_mode_var" '%s' "600"
}

function enable_capture_tls_decrypt() {
  local context="${1:-}"
  local flat_context=""
  flat_context="$(_capture_context_flat "$context")"
  local keylog_dir="" keylog_file="" keylog_name="" timestamp="" old_umask="" keylog_dir_mode="700" keylog_file_mode="600"
  local state_dir="" state_name=""
  capture_tls_keylog_host_dir keylog_dir || return 1
  capture_tls_keylog_permissions keylog_dir_mode keylog_file_mode || return 1
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  keylog_file="${keylog_dir}/tlskeys_${timestamp}.log"
  _capture_tls_path_leaf_name keylog_name "$keylog_file" "TLS key log file" || return 1
  state_dir="$(dirname "$CAPTURE_TLS_STATE_FILE")"
  _capture_tls_path_leaf_name state_name "$CAPTURE_TLS_STATE_FILE" "TLS decrypt state file" || return 1
  _capture_tls_keylog_path_guard "$keylog_file" || return 1
  _capture_tls_state_file_guard || return 1

  old_umask="$(umask)"
  umask 077
  if ! mkdir -p "$keylog_dir"; then
    echo "[Error] Unable to create TLS key log directory: ${keylog_dir}" >&2
    umask "$old_umask"
    return 1
  fi
  _capture_tls_keylog_path_guard "$keylog_file" || {
    umask "$old_umask"
    return 1
  }
  (
    _capture_tls_cd_guarded_keylog_dir "$keylog_dir" || exit 1
    local tmp_keylog=""
    tmp_keylog="$(mktemp ".${keylog_name}.tmp.XXXXXX" 2>/dev/null)" || {
      echo "[Error] Unable to create temp file for TLS key log ${keylog_file}." >&2
      exit 1
    }
    : >"$tmp_keylog" || {
      rm -f "$tmp_keylog"
      exit 1
    }
    chmod "$keylog_dir_mode" . 2>/dev/null || true
    chmod "$keylog_file_mode" "$tmp_keylog" 2>/dev/null || true
    if [ -d "$keylog_name" ]; then
      rm -f "$tmp_keylog"
      echo "[Error] Refusing to replace TLS key log directory with file: ${keylog_file}." >&2
      exit 1
    fi
    mv -f "$tmp_keylog" "$keylog_name" || {
      rm -f "$tmp_keylog"
      echo "[Error] Unable to finalize TLS key log ${keylog_file}." >&2
      exit 1
    }
  ) || {
    umask "$old_umask"
    return 1
  }
  if ! mkdir -p "$state_dir"; then
    echo "[Error] Unable to create TLS decrypt state directory: ${state_dir}" >&2
    umask "$old_umask"
    return 1
  fi
  _capture_tls_state_file_guard || {
    umask "$old_umask"
    return 1
  }
  (
    _capture_tls_cd_guarded_state_dir "$state_dir" || exit 1
    local tmp_state=""
    tmp_state="$(mktemp ".${state_name}.tmp.XXXXXX" 2>/dev/null)" || {
      echo "[Error] Unable to create temp file for TLS decrypt state ${CAPTURE_TLS_STATE_FILE}." >&2
      exit 1
    }
    if ! cat >"$tmp_state" <<EOF
enabled=true
keylog_file=${keylog_file}
started_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
EOF
    then
      rm -f "$tmp_state"
      exit 1
    fi
    chmod 600 "$tmp_state" 2>/dev/null || true
    if [ -d "$state_name" ]; then
      rm -f "$tmp_state"
      echo "[Error] Refusing to replace TLS decrypt state directory with file: ${CAPTURE_TLS_STATE_FILE}." >&2
      exit 1
    fi
    mv -f "$tmp_state" "$state_name" || {
      rm -f "$tmp_state"
      echo "[Error] Unable to finalize TLS decrypt state ${CAPTURE_TLS_STATE_FILE}." >&2
      exit 1
    }
  ) || {
    umask "$old_umask"
    return 1
  }
  umask "$old_umask"

  audit_log "tls_decrypt state_change action=enabled context=\"${flat_context}\" keylog_file=\"${keylog_file}\""
}

function disable_capture_tls_decrypt() {
  local context="${1:-}"
  local flat_context=""
  flat_context="$(_capture_context_flat "$context")"
  _capture_tls_state_file_guard || return 1
  rm -f "$CAPTURE_TLS_STATE_FILE" 2>/dev/null || true

  audit_log "tls_decrypt state_change action=disabled context=\"${flat_context}\""
}
