# shellcheck shell=bash

# Fixture writers deliberately allow invalid values so parser/validation tests
# exercise the persisted boundary instead of failing inside their setup.
function test_global_csv_seed() (
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  local GLOBAL_SETTINGS_FILE="$1" key="" known="" found=false
  local -a GLOBAL_SETTINGS_EXTENSION_HEADERS=() GLOBAL_SETTINGS_EXTENSION_VALUES=()
  local GLOBAL_SETTINGS_EXTENSION_FILE="$1"
  shift
  config_reset_defaults
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || return 1
    key="$1"; found=false
    while IFS= read -r known; do
      if [ "$key" = "$known" ]; then printf -v "$known" '%s' "$2"; found=true; break; fi
    done < <(_global_settings_keys)
    if [ "$found" = false ]; then GLOBAL_SETTINGS_EXTENSION_HEADERS+=("$key"); GLOBAL_SETTINGS_EXTENSION_VALUES+=("$2"); fi
    shift 2
  done
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
)

function test_global_csv_set() (
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  local key=""
  key="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  csv_record_put "$1" "$STATE_GLOBAL_SETTINGS_HEADER" "$key" "$3"
)

function test_global_csv_get() (
  source "$ROOT_DIR/lib/config.sh"
  source "$ROOT_DIR/lib/utils.sh"
  local key=""
  key="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  csv_record_get "$1" "$STATE_GLOBAL_SETTINGS_HEADER" "$key"
)

function test_global_csv_from_legacy() (
  source "$ROOT_DIR/lib/utils/csv.sh"
  local file="$1" line="" line_no=0
  local -a args=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1)); [ "$line_no" -gt 1 ] || continue
    csv_parse_line "$line" && [ "$CSV_FIELD_COUNT" -eq 2 ] || return 1
    args+=("${CSV_FIELDS[@]}")
  done <"$file"
  test_global_csv_seed "$file" "${args[@]+"${args[@]}"}"
)
