# shellcheck shell=bash

function _runtime_path_strip_trailing_slashes() {
  local path="${1:-}"
  while [ "${path%/}" != "$path" ] && [ "$path" != "/" ]; do
    path="${path%/}"
  done
  printf '%s' "$path"
}

function _runtime_path_to_absolute_lexical() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  path="$(_runtime_path_strip_trailing_slashes "$path")"
  case "$path" in
  /*) printf '%s' "$path" ;;
  *) printf '%s/%s' "$PWD" "$path" ;;
  esac
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
  link="$(readlink "$path" 2>/dev/null || true)"

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
  path="$(_runtime_path_to_absolute_lexical "$path")" || return 1
  path="$(_runtime_path_strip_trailing_slashes "$path")"
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
  probe="$(_runtime_path_to_absolute_lexical "$target")" || return 1

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

  resolved="$(_runtime_path_realpath_portable "$probe")" || return 1
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
  local path="${1:-}" root="${STATE_DIR:-}" abs_path="" abs_root=""
  [ -n "$path" ] || return 1
  [ -n "$root" ] || return 1

  abs_path="$(_runtime_path_to_absolute_lexical "$path")" || return 1
  abs_root="$(_runtime_path_to_absolute_lexical "$root")" || return 1

  case "$abs_path" in
  "$abs_root")
    printf ''
    return 0
    ;;
  "$abs_root"/*)
    printf '%s' "${abs_path#"$abs_root"}"
    return 0
    ;;
  esac

  return 1
}

function _runtime_state_declared_suffix_assign() {
  local __out_var="${1:-}" path="${2:-}" root="${STATE_DIR:-}"
  local abs_path="" abs_root="" declared_suffix=""
  [[ "$__out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
  [ -n "$path" ] || return 1
  [ -n "$root" ] || return 1

  abs_path="$(_runtime_path_to_absolute_lexical "$path")" || return 1
  abs_root="$(_runtime_path_to_absolute_lexical "$root")" || return 1

  case "$abs_path" in
  "$abs_root")
    declared_suffix=""
    ;;
  "$abs_root"/*)
    declared_suffix="${abs_path#"$abs_root"}"
    ;;
  *)
    return 1
    ;;
  esac

  printf -v "$__out_var" '%s' "$declared_suffix"
}

function runtime_state_path_is_declared() {
  _runtime_state_declared_suffix "${1:-}" >/dev/null 2>&1
}

function _runtime_state_path_guard_declared_suffix() {
  local label="${1:-runtime path}" suffix="${2:-}"
  local state_root="${STATE_DIR:-}" state_root_abs=""

  [ -n "$state_root" ] || return 0
  state_root="$(_runtime_path_strip_trailing_slashes "$state_root")"
  _runtime_state_root_prefix_guard "$state_root" || return 1
  if [ -L "$state_root" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${state_root}" >&2
    return 1
  fi

  state_root_abs="$(_runtime_path_to_absolute_lexical "$state_root")" || {
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

  current="$(_runtime_path_resolve_allow_missing "$STATE_DIR")" || {
    echo "[Error] Unable to resolve runtime state root: ${STATE_DIR}" >&2
    return 1
  }

  if [ -L "$current" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${STATE_DIR}" >&2
    return 1
  fi

  walk_path="$(_runtime_path_strip_trailing_slashes "$walk_path")"
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

  state_root="$(_runtime_path_strip_trailing_slashes "$state_root")"
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

  state_root="$(_runtime_path_strip_trailing_slashes "$state_root")"
  _runtime_state_root_prefix_guard "$state_root" || return 1
  if [ -L "$state_root" ]; then
    echo "[Error] Refusing to use symlinked runtime state root: ${state_root}" >&2
    return 1
  fi

  if _runtime_state_declared_suffix_assign suffix "$path"; then
    _runtime_state_path_guard_declared_suffix "$label" "$suffix" || return 1
    return 0
  fi

  state_root_norm="$(_runtime_path_resolve_allow_missing "$state_root")" || {
    echo "[Error] Unable to resolve runtime state root: ${state_root}" >&2
    return 1
  }
  path_norm="$(_runtime_path_resolve_allow_missing "$path")" || {
    echo "[Error] Unable to resolve ${label}: ${path}" >&2
    return 1
  }

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
