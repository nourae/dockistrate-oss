# shellcheck shell=bash

# Shared CSV helpers for tool-managed state files.
# These helpers support RFC 4180-style quoted fields:
# - field separators: comma
# - quote escaping: "" inside quoted fields

CSV_FIELDS=()
CSV_FIELD_COUNT=0
CSV_PARSE_ERROR=""

function csv_escape_field() {
  local field="${1-}"
  local needs_quote=0

  case "$field" in
  *","* | *"\""* | *$'\n'* | *$'\r'*)
    needs_quote=1
    ;;
  esac
  case "$field" in
  " "* | *" " | $'\t'* | *$'\t')
    needs_quote=1
    ;;
  esac

  if [ "$needs_quote" -eq 1 ]; then
    field="${field//\"/\"\"}"
    printf '"%s"' "$field"
  else
    printf '%s' "$field"
  fi
}

function csv_join_row() {
  local out="" field escaped=""
  if [ "$#" -eq 0 ]; then
    printf '\n'
    return 0
  fi

  for field in "$@"; do
    escaped="$(csv_escape_field "$field")"
    if [ -z "$out" ]; then
      out="$escaped"
    else
      out="${out},${escaped}"
    fi
  done

  printf '%s\n' "$out"
}

function csv_parse_line() {
  local line="${1-}"
  local current="" ch="" next=""
  local in_quotes=0 just_closed_quote=0
  local i=0 len=0

  CSV_PARSE_ERROR=""
  CSV_FIELDS=()
  CSV_FIELD_COUNT=0

  # Trim only trailing CR for CRLF compatibility.
  line="${line%$'\r'}"
  len=${#line}

  for ((i = 0; i < len; i++)); do
    ch="${line:i:1}"

    if [ "$in_quotes" -eq 1 ]; then
      if [ "$ch" = '"' ]; then
        next="${line:i+1:1}"
        if [ "$next" = '"' ]; then
          current+='"'
          i=$((i + 1))
        else
          in_quotes=0
          just_closed_quote=1
        fi
      else
        current+="$ch"
      fi
      continue
    fi

    if [ "$just_closed_quote" -eq 1 ]; then
      if [ "$ch" = ',' ]; then
        CSV_FIELDS+=("$current")
        current=""
        just_closed_quote=0
      else
        CSV_PARSE_ERROR="unexpected character after closing quote"
        return 1
      fi
      continue
    fi

    case "$ch" in
    ',')
      CSV_FIELDS+=("$current")
      current=""
      ;;
    '"')
      if [ -n "$current" ]; then
        CSV_PARSE_ERROR="unexpected quote in unquoted field"
        return 1
      fi
      in_quotes=1
      ;;
    *)
      current+="$ch"
      ;;
    esac
  done

  if [ "$in_quotes" -eq 1 ]; then
    CSV_PARSE_ERROR="unterminated quoted field"
    return 1
  fi

  CSV_FIELDS+=("$current")
  CSV_FIELD_COUNT=${#CSV_FIELDS[@]}
  return 0
}

function _csv_runtime_state_guard_if_declared() {
  local path="${1:-}" label="${2:-CSV path}"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$path" "$label" || return 1
  fi
}

function _csv_runtime_state_guard_file_and_dir_if_declared() {
  local file="${1:-}" label="${2:-CSV file}"
  local dir=""

  [ -n "$file" ] || return 1
  dir="$(dirname "$file")"
  _csv_runtime_state_guard_if_declared "$dir" "${label} directory" || return 1
  _csv_runtime_state_guard_if_declared "$file" "$label" || return 1
}

function _csv_write_header_file() {
  local file="${1:-}" expected_header="${2:-}" already_guarded="${3:-}" tmp_file=""

  if [ "$already_guarded" != "already_guarded" ]; then
    _csv_runtime_state_guard_file_and_dir_if_declared "$file" "CSV file" || return 1
  fi

  if declare -F make_temp_for_file >/dev/null 2>&1 &&
    declare -F finalize_temp_file >/dev/null 2>&1; then
    make_temp_for_file tmp_file "$file" || return 1
    if ! printf '%s\n' "$expected_header" >"$tmp_file"; then
      rm -f "$tmp_file"
      return 1
    fi
    finalize_temp_file "$file" "$tmp_file"
    return $?
  fi

  printf '%s\n' "$expected_header" >"$file"
}

function csv_require_header() {
  local file="${1:-}" expected_header="${2:-}"
  local first_line="" file_dir=""

  if [ -z "$file" ] || [ -z "$expected_header" ]; then
    echo "[Error] csv_require_header expects <file> and <expected_header>." >&2
    return 1
  fi

  if [ -f "$file" ] && [ -s "$file" ]; then
    _csv_runtime_state_guard_if_declared "$file" "CSV file" || return 1
    IFS= read -r first_line <"$file" || first_line=""
    first_line="${first_line%$'\r'}"
    if [ "$first_line" != "$expected_header" ]; then
      echo "[Error] Invalid header in ${file}. Expected: ${expected_header}" >&2
      return 1
    fi
    return 0
  fi

  file_dir="$(dirname "$file")"
  _csv_runtime_state_guard_file_and_dir_if_declared "$file" "CSV file" || return 1
  if ! mkdir -p "$file_dir"; then
    echo "[Error] Failed to create CSV directory: ${file_dir}" >&2
    return 1
  fi
  _csv_runtime_state_guard_file_and_dir_if_declared "$file" "CSV file" || return 1

  _csv_write_header_file "$file" "$expected_header" already_guarded
}

function csv_append_row() {
  local file="${1:-}" expected_header="${2:-}"
  shift 2 || true

  if ! csv_require_header "$file" "$expected_header"; then
    return 1
  fi

  _csv_runtime_state_guard_if_declared "$file" "CSV file" || return 1
  csv_join_row "$@" >>"$file"
}

function csv_each_row() {
  local file="${1:-}" expected_header="${2:-}" expected_cols="${3:-0}" callback="${4:-}"
  local line="" line_no=0 row_no=0

  if [ -z "$callback" ]; then
    echo "[Error] csv_each_row requires a callback function name." >&2
    return 1
  fi
  if ! declare -F "$callback" >/dev/null 2>&1; then
    echo "[Error] CSV callback function not found: $callback" >&2
    return 1
  fi
  if ! csv_require_header "$file" "$expected_header"; then
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      continue
    fi

    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi

    if [ "$expected_cols" -gt 0 ] && [ "$CSV_FIELD_COUNT" -ne "$expected_cols" ]; then
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${expected_cols}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    row_no=$((row_no + 1))
    "$callback" "$line_no" "$row_no" || return 1
  done <"$file"

  return 0
}

# Rewriter callback return codes:
# 0  -> keep row (possibly modified through CSV_FIELDS)
# 10 -> drop row
function csv_rewrite_rows() {
  local file="${1:-}" expected_header="${2:-}" expected_cols="${3:-0}" callback="${4:-}"
  local line="" line_no=0 row_no=0 rc=0
  local tmp_file=""

  if [ -z "$callback" ]; then
    echo "[Error] csv_rewrite_rows requires a callback function name." >&2
    return 1
  fi
  if ! declare -F "$callback" >/dev/null 2>&1; then
    echo "[Error] CSV callback function not found: $callback" >&2
    return 1
  fi
  if ! csv_require_header "$file" "$expected_header"; then
    return 1
  fi

  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$expected_header" >"$tmp_file"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      continue
    fi

    if ! csv_parse_line "$line"; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi

    if [ "$expected_cols" -gt 0 ] && [ "$CSV_FIELD_COUNT" -ne "$expected_cols" ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${expected_cols}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    row_no=$((row_no + 1))
    "$callback" "$line_no" "$row_no"
    rc=$?
    case "$rc" in
    0)
      csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
      ;;
    10)
      ;;
    *)
      rm -f "$tmp_file"
      return "$rc"
      ;;
    esac
  done <"$file"

  finalize_temp_file "$file" "$tmp_file"
}

function csv_data_row_count() {
  local file="${1:-}" expected_header="${2:-}"
  local count=0 line="" line_no=0

  if ! csv_require_header "$file" "$expected_header"; then
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    count=$((count + 1))
  done <"$file"

  printf '%s\n' "$count"
}
