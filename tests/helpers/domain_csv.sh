# shellcheck shell=bash

# Isolate sourcing and dynamic parser variables from the test's runtime model.
function test_domain_csv_set() (
  source "$ROOT_DIR/lib/utils.sh"
  source "$ROOT_DIR/lib/domain_config/model.sh"
  source "$ROOT_DIR/lib/domain_config/serialization.sh"
  source "$ROOT_DIR/lib/domain_config/record_io.sh"
  _domain_csv_set "$@"
)

# Read the actual named columns independently of the model accessors. This also
# detects fixtures accidentally left in the old vertical representation.
function test_csv_field() (
  source "$ROOT_DIR/lib/utils/csv.sh"
  local file="$1" field="$2" line="" wanted=-1 index=0 rows=0 result=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  IFS= read -r line <"$file" || [ -n "$line" ] || return 1
  csv_parse_line "$line" || return 1
  for ((index = 0; index < CSV_FIELD_COUNT; index++)); do
    [ "${CSV_FIELDS[index]}" != "$field" ] || wanted="$index"
  done
  [ "$wanted" -ge 0 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rows=$((rows + 1))
    [ "$rows" -gt 1 ] || continue
    [ "$rows" -eq 2 ] || return 1
    csv_parse_line "$line" || return 1
    result="${CSV_FIELDS[wanted]}"
  done <"$file"
  printf '%s\n' "$result"
)
