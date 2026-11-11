# shellcheck shell=bash

# Assign pure string results in the caller's shell, preserving literal bytes
# without command-substitution forks. Destinations are ordinary string variables;
# reject our scratch names before declaring locals to avoid dynamic-scope writes.
# Case patterns also leave the caller's BASH_REMATCH untouched.
function _runtime_path_strip_trailing_slashes_assign() {
  case "${1:-}" in
  '' | [!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_]* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]* | _runtime_trim_value)
    return 1
    ;;
  esac
  local _runtime_trim_value="${2:-}"
  while [ "${_runtime_trim_value%/}" != "$_runtime_trim_value" ] && [ "$_runtime_trim_value" != "/" ]; do
    _runtime_trim_value="${_runtime_trim_value%/}"
  done
  printf -v "$1" '%s' "$_runtime_trim_value"
}

function _runtime_path_strip_trailing_slashes() {
  local path=""
  _runtime_path_strip_trailing_slashes_assign path "${1:-}" || return 1
  printf '%s' "$path"
}

function _runtime_path_to_absolute_lexical_assign() {
  case "${1:-}" in
  '' | [!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_]* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]* | _runtime_absolute_value)
    return 1
    ;;
  esac
  local _runtime_absolute_value="${2:-}"
  [ -n "$_runtime_absolute_value" ] || return 1
  _runtime_path_strip_trailing_slashes_assign _runtime_absolute_value "$_runtime_absolute_value" || return 1
  case "$_runtime_absolute_value" in
  /*) ;;
  *) _runtime_absolute_value="$PWD/$_runtime_absolute_value" ;;
  esac
  printf -v "$1" '%s' "$_runtime_absolute_value"
}

function _runtime_path_to_absolute_lexical() {
  local path=""
  _runtime_path_to_absolute_lexical_assign path "${1:-}" || return 1
  printf '%s' "$path"
}

function _runtime_path_realpath_portable() {
  local target="${1:-}"
  [ -n "$target" ] || return 1

  if ! declare -F _realpath_portable >/dev/null 2>&1; then
    # shellcheck source=./utils/fs.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils/fs.sh"
  fi
  _realpath_portable "$target"
}

function _runtime_path_is_allowed_system_symlink() {
  local path="${1:-}" link=""
  [ -n "$path" ] || return 1
  command -v readlink >/dev/null 2>&1 || return 1
  # GNU and BSD readlink -n emit the exact link target, with no delimiter.
  link="$(readlink -n "$path" 2>/dev/null && printf '.')" || return 1
  link="${link%.}"

  # macOS exposes these as root-owned system aliases. They are not operator
  # controlled runtime-state indirections, so allow them as path prefixes.
  case "$path:$link" in
  /tmp:private/tmp | /var:private/var)
    return 0
    ;;
  esac

  return 1
}

function _runtime_path_reject_symlink_prefix_components() {
  local path="${1:-}" label="${2:-runtime path}"
  local current="/" rel="" component="" check_existing=true

  [ -n "$path" ] || return 1
  _runtime_path_to_absolute_lexical_assign path "$path" || return 1
  _runtime_path_strip_trailing_slashes_assign path "$path" || return 1
  [ "$path" = "/" ] && return 0

  rel="${path#/}"
  while [ -n "$rel" ]; do
    component="${rel%%/*}"
    if [ "$rel" = "$component" ]; then
      rel=""
    else
      rel="${rel#*/}"
    fi
    [ -n "$component" ] || continue

    case "$component" in
    . | ..)
      echo "[Error] Refusing to use ${label} containing '${component}' runtime path component: ${path}" >&2
      return 1
      ;;
    esac

    if [ "$current" = "/" ]; then
      current="/${component}"
    else
      current="${current}/${component}"
    fi

    if [ "$check_existing" = true ]; then
      if [ -L "$current" ] && ! _runtime_path_is_allowed_system_symlink "$current"; then
        echo "[Error] Refusing to use symlinked runtime path component for ${label}: ${current}" >&2
        return 1
      fi
      [ -e "$current" ] || check_existing=false
    fi
  done
}

function _runtime_state_root_prefix_guard() {
  local state_root="${1:-}"
  [ -n "$state_root" ] || return 1

  _runtime_path_reject_symlink_prefix_components "$state_root" "runtime state root"
}

function _runtime_path_resolve_allow_missing() {
  local target="${1:-}"
  local probe="" suffix="" base="" parent="" resolved=""

  [ -n "$target" ] || return 1
  _runtime_path_to_absolute_lexical_assign probe "$target" || return 1

  while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    base="${probe##*/}"
    [ -n "$base" ] && [ "$base" != "/" ] || return 1
    if [ -n "$suffix" ]; then
      suffix="${base}/${suffix}"
    else
      suffix="$base"
    fi

    parent="${probe%/*}"
    if [ -z "$parent" ] || [ "$parent" = "$probe" ]; then
      parent="/"
    fi
    probe="$parent"
  done

  resolved="$(_runtime_path_realpath_portable "$probe" && printf '.')" || return 1
  resolved="${resolved%.}"
  if [ -n "$suffix" ]; then
    if [ "$resolved" = "/" ]; then
      printf '/%s' "$suffix"
    else
      printf '%s/%s' "$resolved" "$suffix"
    fi
  else
    printf '%s' "$resolved"
  fi
}

function _runtime_state_declared_suffix() {
  local declared_suffix=""
  _runtime_state_declared_suffix_assign declared_suffix "${1:-}" || return 1
  printf '%s' "$declared_suffix"
  return 0
}

function _runtime_state_declared_suffix_assign() {
  case "${1:-}" in
  '' | [!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_]* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]* | _runtime_suffix_path | _runtime_suffix_root | _runtime_suffix_value)
    return 1
    ;;
  esac
  local _runtime_suffix_path="${2:-}" _runtime_suffix_root="${STATE_DIR:-}" _runtime_suffix_value=""
  [ -n "$_runtime_suffix_path" ] || return 1
  [ -n "$_runtime_suffix_root" ] || return 1

  _runtime_path_to_absolute_lexical_assign _runtime_suffix_path "$_runtime_suffix_path" || return 1
  _runtime_path_to_absolute_lexical_assign _runtime_suffix_root "$_runtime_suffix_root" || return 1

  case "$_runtime_suffix_path" in
  "$_runtime_suffix_root") ;;
  "$_runtime_suffix_root"/*)
    _runtime_suffix_value="${_runtime_suffix_path#"$_runtime_suffix_root"}"
    ;;
  *)
    return 1
    ;;
  esac

  printf -v "$1" '%s' "$_runtime_suffix_value"
}

function runtime_state_path_is_declared() {
  _runtime_state_declared_suffix "${1:-}" >/dev/null 2>&1
}

function _runtime_state_path_guard_declared_suffix() {
  local label="${1:-runtime path}" suffix="${2:-}"
  local state_root="${STATE_DIR:-}" state_root_abs=""

  [ -n "$state_root" ] || return 0
  _runtime_path_strip_trailing_slashes_assign state_root "$state_root" || return 1
  _runtime_state_root_prefix_guard "$state_root" || return 1
  if [ -L "$state_root" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${state_root}" >&2
    return 1
  fi

  _runtime_path_to_absolute_lexical_assign state_root_abs "$state_root" || {
    echo "[Error] Unable to resolve runtime state root: ${state_root}" >&2
    return 1
  }
  _runtime_state_reject_declared_symlink_components "$state_root_abs" "$suffix" "$label" || return 1
}

function _runtime_state_reject_symlink_components() {
  local walk_path="${1:-}" label="${2:-runtime path}" original="${3:-}"
  local current="" rel="" component=""

  [ -n "$walk_path" ] || return 1
  [ -n "${STATE_DIR:-}" ] || return 0

  current="$(_runtime_path_resolve_allow_missing "$STATE_DIR" && printf '.')" || {
    echo "[Error] Unable to resolve runtime state root: ${STATE_DIR}" >&2
    return 1
  }
  current="${current%.}"

  if [ -L "$current" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${STATE_DIR}" >&2
    return 1
  fi

  _runtime_path_strip_trailing_slashes_assign walk_path "$walk_path" || return 1
  case "$walk_path" in
  "$current")
    return 0
    ;;
  "$current"/*)
    rel="${walk_path#"$current"/}"
    ;;
  *)
    echo "[Error] Refusing to use ${label} outside runtime state root: ${original:-$walk_path}" >&2
    return 1
    ;;
  esac

  while [ -n "$rel" ]; do
    component="${rel%%/*}"
    if [ "$rel" = "$component" ]; then
      rel=""
    else
      rel="${rel#*/}"
    fi
    [ -n "$component" ] || continue
    current="${current%/}/${component}"

    if [ -L "$current" ]; then
      echo "[Error] Refusing to use symlinked runtime path component for ${label}: ${current}" >&2
      return 1
    fi
    [ -e "$current" ] || break
  done
}

function _runtime_state_reject_declared_symlink_components() {
  local state_root="${1:-}" suffix="${2:-}" label="${3:-runtime path}"
  local current="" rel="" component="" check_existing=true

  [ -n "$state_root" ] || return 1

  _runtime_path_strip_trailing_slashes_assign state_root "$state_root" || return 1
  if [ -L "$state_root" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${state_root}" >&2
    return 1
  fi

  current="$state_root"
  rel="${suffix#/}"

  while [ -n "$rel" ]; do
    component="${rel%%/*}"
    if [ "$rel" = "$component" ]; then
      rel=""
    else
      rel="${rel#*/}"
    fi
    [ -n "$component" ] || continue

    case "$component" in
    . | ..)
      echo "[Error] Refusing to use ${label} containing '${component}' path component under runtime state root." >&2
      return 1
      ;;
    esac

    current="${current%/}/${component}"

    if [ "$check_existing" = true ]; then
      if [ -L "$current" ]; then
        echo "[Error] Refusing to use symlinked runtime path component for ${label}: ${current}" >&2
        return 1
      fi
      [ -e "$current" ] || check_existing=false
    fi
  done
}

function runtime_state_path_guard() {
  local path="${1:-}" label="${2:-runtime path}"
  local state_root="${STATE_DIR:-}" state_root_abs="" state_root_norm="" path_norm="" suffix="" walk_path=""

  [ -n "$path" ] || {
    echo "[Error] Runtime path guard requires a path for ${label}." >&2
    return 1
  }
  [ -n "$state_root" ] || return 0

  _runtime_path_strip_trailing_slashes_assign state_root "$state_root" || return 1
  _runtime_state_root_prefix_guard "$state_root" || return 1
  if [ -L "$state_root" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${state_root}" >&2
    return 1
  fi

  if _runtime_state_declared_suffix_assign suffix "$path"; then
    _runtime_state_path_guard_declared_suffix "$label" "$suffix" || return 1
    return 0
  fi

  state_root_norm="$(_runtime_path_resolve_allow_missing "$state_root" && printf '.')" || {
    echo "[Error] Unable to resolve runtime state root: ${state_root}" >&2
    return 1
  }
  state_root_norm="${state_root_norm%.}"
  path_norm="$(_runtime_path_resolve_allow_missing "$path" && printf '.')" || {
    echo "[Error] Unable to resolve ${label}: ${path}" >&2
    return 1
  }
  path_norm="${path_norm%.}"

  case "$path_norm" in
  "$state_root_norm" | "$state_root_norm"/*) ;;
  *)
    echo "[Error] Refusing to use ${label} outside runtime state root: ${path} (resolved: ${path_norm}, state: ${state_root_norm})" >&2
    return 1
    ;;
  esac

  walk_path="$path_norm"
  _runtime_state_reject_symlink_components "$walk_path" "$label" "$path" || return 1
}

function runtime_state_path_guard_if_declared() {
  local path="${1:-}" label="${2:-runtime path}"
  local suffix=""
  if _runtime_state_declared_suffix_assign suffix "$path"; then
    _runtime_state_path_guard_declared_suffix "$label" "$suffix" || return 1
  fi
}

function runtime_state_paths_guard_if_declared() {
  local path=""
  for path in "$@"; do
    [ -n "$path" ] || continue
    runtime_state_path_guard_if_declared "$path" "runtime path" || return 1
  done
}

function runtime_state_paths_guard() {
  local path=""
  for path in "$@"; do
    [ -n "$path" ] || continue
    runtime_state_path_guard "$path" "runtime path" || return 1
  done
}

function __dockistrate_runtime_paths_loaded() {
  :
}
