# shellcheck shell=bash
function _realpath_portable() {
  local target="${1:-}"
  local max_links=40
  local dir=""
  local base=""
  local link=""
  local start_dir="$PWD"
  local resolved=""
  local resolved_dir=""

  [ -n "$target" ] || return 1

  if command -v realpath >/dev/null 2>&1; then
    if resolved="$(realpath "$target" 2>/dev/null)"; then
      printf '%s' "$resolved"
      return 0
    fi
  fi

  while [ "${target%/}" != "$target" ] && [ "$target" != "/" ]; do
    target="${target%/}"
  done

  if [ "${target#/}" = "$target" ]; then
    target="$start_dir/$target"
  fi

  while [ $max_links -gt 0 ]; do
    dir="${target%/*}"
    base="${target##*/}"

    if [ -z "$dir" ] || [ "$dir" = "$target" ]; then
      dir="/"
      base="${target#/}"
      [ -n "$base" ] || base="/"
    fi

    if ! cd "$dir" 2>/dev/null; then
      cd "$start_dir" 2>/dev/null || true
      return 1
    fi

    resolved_dir="$(pwd -P 2>/dev/null)" || {
      cd "$start_dir" 2>/dev/null || true
      return 1
    }

    if [ "$base" = "/" ]; then
      cd "$start_dir" 2>/dev/null || true
      printf '/'
      return 0
    fi

    if [ -L "$base" ]; then
      if ! command -v readlink >/dev/null 2>&1; then
        cd "$start_dir" 2>/dev/null || true
        return 1
      fi
      link="$(readlink "$base")" || {
        cd "$start_dir" 2>/dev/null || true
        return 1
      }
      if [ "${link#/}" = "$link" ]; then
        target="$resolved_dir/$link"
      else
        target="$link"
      fi
      cd "$start_dir" 2>/dev/null || true
      max_links=$((max_links - 1))
      continue
    fi

    if [ -e "$base" ] || [ ! -L "$base" ]; then
      resolved="$resolved_dir/$base"
      cd "$start_dir" 2>/dev/null || true
      printf '%s' "$resolved"
      return 0
    fi

    cd "$start_dir" 2>/dev/null || true
    return 1
  done

  cd "$start_dir" 2>/dev/null || true
  return 1
}

function file_exists() { [ -f "${1:-}" ]; }

# Escape characters with special meaning in extended regular expressions so
# that the literal value can be safely embedded in sed patterns.
function escape_sed_literal() {
  local value="${1:-}"
  printf '%s' "$value" | sed 's/[][{}()*+?.^$|\\/]/\\&/g'
}

# Cross-platform in-place sed (works on GNU and BSD/macOS)
function sed_in_place() {
  local expr="${1:-}"
  local file="${2:-}"
  if [[ "$(uname)" == "Darwin" ]]; then
    # BSD sed treats \+ as a literal plus with -E, so convert to unescaped
    expr="${expr//\\+/+}"
    sed -E -i '' "$expr" "$file"
  else
    sed -E -i "$expr" "$file"
  fi
}

# Replace a specific line within a file (1-indexed)
function replace_line() {
  local file="${1:-}" line_num="${2:-}" new_line="${3:-}"
  if [ -z "$file" ] || [ -z "$line_num" ] || [ -z "$new_line" ]; then
    echo "[Usage] replace_line <file> <line_num> <new_line>"
    return 1
  fi
  if ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
    echo "[Error] line_num must be numeric" >&2
    return 1
  fi
  [ -f "$file" ] || {
    echo "[Error] File '$file' not found" >&2
    return 1
  }
  local tmp_file=""
  make_temp_for_file tmp_file "$file" || return 1
  if awk -v n="$line_num" -v line="$new_line" 'NR==n{print line; next}1' "$file" >"$tmp_file"; then
    finalize_temp_file "$file" "$tmp_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Move a specific line within a file to a new position (1-indexed)
function move_line() {
  local file="${1:-}" from="${2:-}" to="${3:-}"
  if [ -z "$file" ] || [ -z "$from" ] || [ -z "$to" ]; then
    echo "[Usage] move_line <file> <from> <to>"
    return 1
  fi
  if ! [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]]; then
    echo "[Error] Positions must be numeric" >&2
    return 1
  fi
  [ -f "$file" ] || {
    echo "[Error] File '$file' not found" >&2
    return 1
  }
  local tmp_file=""
  make_temp_for_file tmp_file "$file" || return 1
  if awk -v f="$from" -v t="$to" '{ if(NR==f){line=$0;next} lines[++n]=$0 } END { if(t<1) t=1; if(t>n+1) t=n+1; for(i=1;i<=n+1;i++){ if(i==t) print line; if(i<=n) print lines[i]; } }' "$file" >"$tmp_file"; then
    finalize_temp_file "$file" "$tmp_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Create and finalize temp files safely alongside a target file.
function make_temp_for_file() {
  local __outvar="${1:-}" target="${2:-}"
  require_valid_var_name "$__outvar" || return 1
  if [ -z "$target" ]; then
    echo "[Error] Target file path required" >&2
    return 1
  fi
  local __mtf_dir __mtf_base __mtf_tmp __mtf_old_umask
  __mtf_dir="$(dirname "$target")"
  __mtf_base="$(basename "$target")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$__mtf_dir" "temp file directory" || return 1
    runtime_state_path_guard_if_declared "$target" "temp file target" || return 1
  fi
  __mtf_old_umask="$(umask)"
  umask 077
  __mtf_tmp="$(mktemp "${__mtf_dir}/.${__mtf_base}.tmp.XXXXXX" 2>/dev/null)" || {
    umask "$__mtf_old_umask"
    echo "[Error] Unable to create temp file for $target" >&2
    return 1
  }
  umask "$__mtf_old_umask"
  printf -v "$__outvar" '%s' "$__mtf_tmp"
}

function finalize_temp_file() {
  local target="${1:-}" tmp="${2:-}"
  if [ -z "$target" ] || [ -z "$tmp" ]; then
    echo "[Error] finalize_temp_file requires target and temp paths" >&2
    return 1
  fi
  if [ ! -f "$tmp" ]; then
    echo "[Error] Temp file not found: $tmp" >&2
    return 1
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$target" "temp file target" || return 1
    runtime_state_path_guard_if_declared "$tmp" "temp file" || return 1
  fi

  local mode=""
  if [ -f "$target" ]; then
    mode="$(stat -c '%a' "$target" 2>/dev/null || true)"
    if [ -z "$mode" ]; then
      mode="$(stat -f '%Lp' "$target" 2>/dev/null || true)"
    fi
  fi

  if [ -n "$mode" ]; then
    chmod "$mode" "$tmp" 2>/dev/null || true
  else
    chmod 644 "$tmp" 2>/dev/null || true
  fi

  mv -f "$tmp" "$target"
}

function finalize_temp_file_with_mode() {
  local target="${1:-}" tmp="${2:-}" mode="${3:-}"
  if [ -z "$target" ] || [ -z "$tmp" ] || [ -z "$mode" ]; then
    echo "[Error] finalize_temp_file_with_mode requires target, temp path, and mode" >&2
    return 1
  fi
  if [ ! -f "$tmp" ]; then
    echo "[Error] Temp file not found: $tmp" >&2
    return 1
  fi
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$target" "temp file target" || return 1
    runtime_state_path_guard_if_declared "$tmp" "temp file" || return 1
  fi

  if ! chmod "$mode" "$tmp" 2>/dev/null; then
    echo "[Error] Failed to set mode ${mode} on temp file ${tmp}" >&2
    return 1
  fi

  if ! mv -f "$tmp" "$target"; then
    echo "[Error] Failed to replace ${target} atomically" >&2
    return 1
  fi
}

function copy_file_atomic() {
  local source="${1:-}" target="${2:-}" mode="${3:-644}"
  if [ -z "$source" ] || [ -z "$target" ]; then
    echo "[Usage] copy_file_atomic <source> <target> [mode]" >&2
    return 1
  fi
  [ -f "$source" ] || {
    echo "[Error] Source file not found: $source" >&2
    return 1
  }

  local target_dir tmp_file="" old_umask
  target_dir="$(dirname "$target")"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$target_dir" "copy target directory" || return 1
    runtime_state_path_guard_if_declared "$target" "copy target file" || return 1
  fi
  mkdir -p "$target_dir" || {
    echo "[Error] Failed to create target directory: $target_dir" >&2
    return 1
  }

  make_temp_for_file tmp_file "$target" || return 1
  old_umask="$(umask)"
  umask 077
  if ! cat "$source" >"$tmp_file"; then
    umask "$old_umask"
    safe_rm_f "$tmp_file" "$target_dir" >/dev/null 2>&1 || rm -f "$tmp_file"
    echo "[Error] Failed to copy ${source} to ${target}" >&2
    return 1
  fi
  umask "$old_umask"

  if ! finalize_temp_file_with_mode "$target" "$tmp_file" "$mode"; then
    safe_rm_f "$tmp_file" "$target_dir" >/dev/null 2>&1 || rm -f "$tmp_file"
    return 1
  fi
}

function _normalize_delete_target_path() {
  local path="${1:-}"
  [ -n "$path" ] || return 1

  while [ "${path%/}" != "$path" ] && [ "$path" != "/" ]; do
    path="${path%/}"
  done

  local parent base resolved_parent
  parent="${path%/*}"
  base="${path##*/}"

  if [ -z "$parent" ] || [ "$parent" = "$path" ]; then
    parent="."
  fi

  [ -n "$base" ] || return 1
  [ "$base" != "." ] || return 1
  [ "$base" != ".." ] || return 1

  if ! resolved_parent="$(_realpath_portable "$parent" 2>/dev/null)"; then
    return 1
  fi

  if [ "$resolved_parent" = "/" ]; then
    printf '/%s' "$base"
  else
    printf '%s/%s' "$resolved_parent" "$base"
  fi
}

function _safe_delete_validate_target() {
  local target="${1:-}"
  shift || true
  [ -n "$target" ] || {
    echo "[Error] Refusing to delete an empty path." >&2
    return 1
  }
  if [ "$target" = "/" ]; then
    echo "[Error] Refusing to delete root path '/'." >&2
    return 1
  fi

  local target_norm root root_norm within_allowed=false
  if ! target_norm="$(_normalize_delete_target_path "$target")"; then
    echo "[Error] Refusing to delete unresolved path: $target" >&2
    return 1
  fi

  case "$target_norm" in
  /)
    echo "[Error] Refusing to delete root path '/'." >&2
    return 1
    ;;
  esac

  for root in "$@"; do
    [ -n "$root" ] || continue
    if ! root_norm="$(_normalize_delete_target_path "$root")"; then
      if ! root_norm="$(_realpath_portable "$root" 2>/dev/null)"; then
        continue
      fi
    fi
    case "$target_norm" in
    "$root_norm" | "$root_norm"/*)
      within_allowed=true
      break
      ;;
    esac
  done

  if [ "$within_allowed" != "true" ]; then
    echo "[Error] Refusing to delete '$target' (normalized: '$target_norm') outside allowed roots." >&2
    return 1
  fi

  printf '%s' "$target_norm"
}

function safe_rm_rf() {
  local target="${1:-}"
  shift || true

  [ -n "$target" ] || {
    echo "[Error] Refusing to delete an empty path." >&2
    return 1
  }
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi

  local target_norm
  if ! target_norm="$(_safe_delete_validate_target "$target" "$@")"; then
    return 1
  fi

  rm -rf "$target_norm"
}

function safe_rm_f() {
  local target="${1:-}"
  shift || true

  [ -n "$target" ] || {
    echo "[Error] Refusing to delete an empty path." >&2
    return 1
  }
  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    return 0
  fi

  local target_norm
  if ! target_norm="$(_safe_delete_validate_target "$target" "$@")"; then
    return 1
  fi

  rm -f "$target_norm"
}

# Read a line with readline editing (arrow/home/end) when TTY is available.
# Falls back to plain read elsewhere. Optional third argument sets default when empty.
function read_with_editing() {
  local prompt="$1" __out="$2" __default="${3:-}" __val=""
  if [[ ! "$__out" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__out" >&2
    return 1
  fi
  if [ -t 0 ] && [ -t 1 ]; then
    read -r -e -p "$prompt" __val || true
  else
    read -r -p "$prompt" __val || true
  fi
  if [ -z "$__val" ] && [ -n "$__default" ]; then
    __val="$__default"
  fi
  printf -v "$__out" '%s' "$__val"
}

function read_multiline_with_editing() {
  local prompt="$1" __out="$2" __default="${3:-}" __line="" __val="" __first=true
  if [[ ! "$__out" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__out" >&2
    return 1
  fi

  while true; do
    local line_prompt="$prompt"
    local read_status=0
    if [ "$__first" != true ]; then
      line_prompt="> "
    fi

    __line=""
    if [ -t 0 ] && [ -t 1 ]; then
      if ! read -r -e -p "$line_prompt" __line; then
        read_status=$?
      fi
    else
      if ! read -r -p "$line_prompt" __line; then
        read_status=$?
      fi
    fi

    if [ "$read_status" -ne 0 ]; then
      # EOF or read error: treat as empty input and exit.
      if [ "$__first" = true ] && [ -n "$__default" ]; then
        __val="$__default"
      fi
      break
    fi

    if [ -z "$__line" ]; then
      if [ "$__first" = true ] && [ -n "$__default" ]; then
        __val="$__default"
      fi
      break
    fi

    if [ "$__first" = true ]; then
      __val="$__line"
      __first=false
    else
      __val+=$'\n'"$__line"
    fi
  done

  printf -v "$__out" '%s' "$__val"
}

function cleanup_leftovers() {
  local leftover_file="${NGINX_HTTP_CONF_DIR}/server_header.conf"
  if [ -f "$leftover_file" ]; then
    rm -f "$leftover_file"
    echo "[Info] Removed leftover file '$leftover_file'."
    log_msg "Removed leftover file $leftover_file."
  fi

}
