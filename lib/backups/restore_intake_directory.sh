# shellcheck shell=bash

function _restore_intake_directory_inventory() {
  local entry_limit="${1:-}" entry="" count=0 complete=false
  while IFS= read -r -d '' -n 8193 entry; do
    if [ -z "$entry" ]; then complete=true; continue; fi
    if [ "${#entry}" -gt 8192 ]; then
      echo "[Error] Backup directory contains an overlong entry path." >&2
      return 1
    fi
    count=$((count + 1))
    if [ "$count" -gt "$entry_limit" ]; then
      echo "[Error] Backup directory exceeds RESTORE_MAX_ENTRIES ($entry_limit)." >&2
      return 1
    fi
    printf '%s\0' "$entry" || return 1
    entry=""
  done
  [ "$complete" = true ]
}

# Directory backups preserve ordinary access bits, including read-only keys.
# BSD %Lp omits special bits; %p exposes the full mode for an explicit mask.
function _restore_intake_file_mode() {
  local path="${1:-}" mode="" digits=4
  case "$path" in -*) path="./$path" ;; esac
  # Keep portability-probe failures local, including Bash 3 command/ERR behavior.
  if mode="$(trap - ERR; command stat -c '%a' -- "$path" 2>/dev/null || exit 1)"; then
    :
  elif mode="$(trap - ERR; command stat -f '%p' "$path" 2>/dev/null || exit 1)"; then
    digits=7
  else
    return 1
  fi
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  [ "${#mode}" -le "$digits" ] || return 1
  [ "$((8#$mode))" -le 65535 ] || return 1
  printf '%05o\n' "$((8#$mode & 0777))"
}

# Open the source parent as the current directory before opening a file. A
# pathname swap of an ancestor cannot redirect that later open outside the tree.
function _restore_intake_copy_directory_file() (
  local entry="${1:-}" destination="${2:-}" remaining="${3:-}" physical="${4:-}"
  local parent="${entry%/*}" leaf="${entry##*/}" expected="" current="" mode=""
  expected="$physical"
  [ "$parent" = . ] || expected="$physical/${parent#./}"
  cd "$parent" || return 1
  current="$(pwd -P && printf '.')" || return 1
  current="${current%$'\n.'}"
  [ "$current" = "$expected" ] && [ ! -L "./$leaf" ] || {
    echo "[Error] Backup directory ancestry changed while creating its snapshot: $entry" >&2
    return 1
  }
  mode="$(_restore_intake_file_mode "./$leaf")" || return 1
  _restore_intake_copy_regular "./$leaf" "$destination" "$remaining" \
    "Backup directory contents (RESTORE_MAX_EXPANDED_BYTES)" false || return 1
  chmod "$mode" "$destination"
)

function _restore_intake_directory() (
  local source="${1:-}" workspace="${2:-}" expanded_limit="${3:-}" entry_limit="${4:-}"
  local physical="" workspace_physical="" identity="" entry="" relative="" destination="" size="" current="" total=0
  local inventory="$workspace/directory_entries" snapshot="$workspace/directory"
  [ -d "$source" ] && [ ! -L "$source" ] || return 1
  identity="$(_backup_directory_identity "$source")" || return 1
  physical="$(cd "$source" && pwd -P && printf '.')" || return 1
  physical="${physical%$'\n.'}"
  workspace_physical="$(cd "$workspace" && pwd -P && printf '.')" || return 1
  workspace_physical="${workspace_physical%$'\n.'}"
  case "$workspace_physical" in "$physical" | "$physical"/*)
    echo "[Error] Refusing to stage a backup directory inside its source." >&2
    return 1
    ;;
  esac
  cd "$source" || return 1
  current="$(pwd -P && printf '.')" || return 1
  current="${current%$'\n.'}"
  [ "$current" = "$physical" ] && [ "$(_backup_directory_identity .)" = "$identity" ] || {
    echo "[Error] Backup directory changed identity while preparing its restore snapshot: $source" >&2
    return 1
  }
  mkdir -m 700 "$snapshot" || return 1
  if [ "$(_backup_directory_identity "$physical")" != "$identity" ]; then
    echo "[Error] Backup directory changed identity while preparing its restore snapshot: $source" >&2
    return 1
  fi
  # The success sentinel distinguishes a complete find from producer failure.
  if ! { find . -print0 && printf '\0'; } |
    _restore_intake_directory_inventory "$entry_limit" >"$inventory"; then return 1; fi
  while IFS= read -r -d '' entry; do
    [ "$entry" != . ] || continue
    case "$entry" in ./*) relative="${entry#./}" ;; *) return 1 ;; esac
    destination="$snapshot/$relative"
    if [ -L "$entry" ]; then
      echo "[Error] Backup directory contains a symlink: $entry" >&2
      return 1
    elif [ -d "$entry" ]; then
      current="$(cd "$entry" && pwd -P && printf '.')" || return 1
      current="${current%$'\n.'}"
      [ "$current" = "$physical/$relative" ] || {
        echo "[Error] Backup directory ancestry changed while creating its snapshot: $entry" >&2
        return 1
      }
      mkdir -m 700 "$destination" || return 1
    elif [ -f "$entry" ]; then
      # Copy only the admitted inventory, bounding each open stream by the
      # remaining total. Concurrent growth cannot exceed the byte budget.
      _restore_intake_copy_directory_file "$entry" "$destination" "$((expanded_limit - total))" "$physical" || return 1
      size="$(_restore_intake_size "$destination")" || return 1
      total=$((total + size))
    else
      echo "[Error] Backup directory contains an unsupported or missing filesystem object: $entry" >&2
      return 1
    fi
  done <"$inventory"
  [ "$(_backup_directory_identity .)" = "$identity" ] &&
    [ "$(_backup_directory_identity "$physical")" = "$identity" ] || {
    echo "[Error] Backup directory changed identity while creating its restore snapshot: $source" >&2
    return 1
  }
  _validate_backup_directory_tree_safe "$snapshot"
)
