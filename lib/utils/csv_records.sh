# shellcheck shell=bash

# Header-aware, read-only record reader. Callbacks receive file, physical line,
# and values in canonical field order. Extra inert columns are opt-in; their
# names follow the required fields in the dynamically scoped header array.
function csv_read_records() {
  local file="$1" schema="$2" callback="$3" cardinality="${4:-table}" extensions="${5:-false}"
  local line="" line_no=0 count=0 i=0 j=0 found=0 name="" remaining="" seen=$'\n'
  local -a CSV_FIELDS=() CSV_RECORD_HEADERS=() input_headers=() mapping=() values=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ ! -L "$file" ] || { echo "[Error] CSV symlink is not allowed: $file" >&2; return 1; }
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -s "$file" ] || { echo "[Error] Expected headed CSV: $file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      # Canonical unquoted headers already have the required order. Split by
      # field rather than parsing every character and searching every pair.
      # Validate names even here: callers may supply an invalid schema.
      if [ "${line%$'\r'}" = "$schema" ] && [[ "$schema" != *'"'* ]]; then
        remaining="$schema"
        while [[ "$remaining" == *,* ]]; do
          input_headers+=("${remaining%%,*}")
          remaining="${remaining#*,}"
        done
        input_headers+=("$remaining")
        for name in "${input_headers[@]}"; do
          case "$name" in '' | *$'\r'* | *$'\n'*) echo "[Error] $file: invalid field name" >&2; return 1 ;; esac
          case "$seen" in *$'\n'"$name"$'\n'*) echo "[Error] $file: duplicate field $name" >&2; return 1 ;; esac
          seen="${seen}${name}"$'\n'
          mapping+=("${#mapping[@]}")
        done
        CSV_RECORD_HEADERS=("${input_headers[@]}")
        continue
      fi
      csv_parse_line "$schema" || return 1
      CSV_RECORD_HEADERS=("${CSV_FIELDS[@]}")
    fi
    csv_parse_line "$line" || { echo "[Error] $file:$line_no: $CSV_PARSE_ERROR" >&2; return 1; }
    if [ "$line_no" -eq 1 ]; then
      input_headers=("${CSV_FIELDS[@]}")
      for name in "${input_headers[@]}"; do
        case "$name" in '' | *$'\r'* | *$'\n'*) echo "[Error] $file: invalid field name" >&2; return 1 ;; esac
        case "$seen" in *$'\n'"$name"$'\n'*) echo "[Error] $file: duplicate field $name" >&2; return 1 ;; esac
        seen="${seen}${name}"$'\n'
        found=0
        for ((i = 0; i < ${#CSV_RECORD_HEADERS[@]}; i++)); do
          [ "${CSV_RECORD_HEADERS[i]}" != "$name" ] || found=1
        done
        if [ "$found" -eq 0 ]; then
          [ "$extensions" = true ] || { echo "[Error] $file: unknown field $name" >&2; return 1; }
          CSV_RECORD_HEADERS+=("$name")
        fi
      done
      for ((i = 0; i < ${#CSV_RECORD_HEADERS[@]}; i++)); do
        found=0
        for ((j = 0; j < ${#input_headers[@]}; j++)); do
          if [ "${CSV_RECORD_HEADERS[i]}" = "${input_headers[j]}" ]; then mapping+=("$j"); found=1; break; fi
        done
        [ "$found" -eq 1 ] || { echo "[Error] $file: missing field ${CSV_RECORD_HEADERS[i]}" >&2; return 1; }
      done
      continue
    fi
    [ "$CSV_FIELD_COUNT" -eq "${#input_headers[@]}" ] || { echo "[Error] $file:$line_no: Invalid CSV record width (expected ${#input_headers[@]} columns, found $CSV_FIELD_COUNT)" >&2; return 1; }
    count=$((count + 1))
    [ "$cardinality" != singleton ] || [ "$count" -eq 1 ] || { echo "[Error] $file:$line_no: Invalid singleton CSV: expected at most one record" >&2; return 1; }
    values=()
    for ((i = 0; i < ${#mapping[@]}; i++)); do
      name="${CSV_FIELDS[${mapping[i]}]}"
      case "$name" in *$'\r'* | *$'\n'*) echo "[Error] $file:$line_no: multiline cells are not supported" >&2; return 1 ;; esac
      values+=("$name")
    done
    "$callback" "$file" "$line_no" "${values[@]}" || return 1
  done <"$file"
}

function _csv_record_capture() {
  shift 2
  _csv_record_values=("$@")
  _csv_record_present=true
}

function csv_record_get() {
  local file="$1" schema="$2" key="$3" fallback="${4-}" i=0 _csv_record_present=false
  local -a _csv_record_values=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  csv_read_records "$file" "$schema" _csv_record_capture singleton || return 1
  if [ "$_csv_record_present" = true ]; then
    csv_parse_line "$schema" || return 1
    for ((i = 0; i < ${#CSV_FIELDS[@]}; i++)); do
      if [ "${CSV_FIELDS[i]}" = "$key" ]; then printf '%s\n' "${_csv_record_values[i]}"; return 0; fi
    done
    echo "[Error] Unknown CSV field $key in $file" >&2; return 1
  fi
  printf '%s\n' "$fallback"
}

function csv_record_put() {
  local file="$1" schema="$2" key="$3" value="${4-}" i=0 matched=false temporary="" _csv_record_present=false
  local -a _csv_record_values=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  _csv_runtime_state_guard_file_and_dir_if_declared "$file" 'CSV record' || return 1
  csv_read_records "$file" "$schema" _csv_record_capture singleton || return 1
  csv_parse_line "$schema" || return 1
  for ((i = 0; i < ${#CSV_FIELDS[@]}; i++)); do
    [ "$_csv_record_present" = true ] || _csv_record_values[i]=''
    if [ "${CSV_FIELDS[i]}" = "$key" ]; then _csv_record_values[i]="$value"; matched=true; fi
  done
  [ "$matched" = true ] || { echo "[Error] Unknown CSV field $key in $file" >&2; return 1; }
  mkdir -p "${file%/*}" || return 1
  make_temp_for_file temporary "$file" || return 1
  if ! { printf '%s\n' "$schema" && csv_join_row "${_csv_record_values[@]}"; } >"$temporary"; then rm -f "$temporary"; return 1; fi
  finalize_temp_file "$file" "$temporary"
}
