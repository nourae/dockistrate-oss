# shellcheck shell=bash

# Update one field in a complete record. This is used only inside staged
# candidates; publication and source compare-and-swap belong to the transaction.
function _domain_csv_set() {
  local file="$1" _dc_set_key="" _dc_set_value="" _dc_set_keys=0 _dc_set_index=0 _dc_set_found=false
  local header="" cardinality="" temporary="" i=0 j=0 identity=false
  local -a _dc_set_ids=() _dc_set_indexes=() _dc_set_values=() _dc_set_rows=() CSV_FIELDS=() DOMAIN_CSV_KEY_INDEXES=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  shift
  _domain_csv_schema "${file##*/}" || return 1
  header="$DOMAIN_CSV_HEADER"; cardinality="$DOMAIN_CSV_CARDINALITY"
  _domain_csv_entity_key_indexes "${file##*/}" || return 1
  _dc_set_keys="${#DOMAIN_CSV_KEY_INDEXES[@]}"
  _dc_set_indexes=("${DOMAIN_CSV_KEY_INDEXES[@]+"${DOMAIN_CSV_KEY_INDEXES[@]}"}")
  [ "$#" -eq "$((_dc_set_keys + 2))" ] || return 1
  for ((i = 0; i < _dc_set_keys; i++)); do _dc_set_ids+=("$1"); shift; done
  _dc_set_key="$1"; _dc_set_value="$2"
  csv_parse_line "$header" || return 1
  _dc_set_index=-1
  for ((i = 0; i < ${#CSV_FIELDS[@]}; i++)); do
    _dc_set_values+=("")
    identity=false
    for ((j = 0; j < _dc_set_keys; j++)); do [ "$i" != "${_dc_set_indexes[j]}" ] || identity=true; done
    if [ "${CSV_FIELDS[i]}" = "$_dc_set_key" ] && [ "$identity" = false ]; then _dc_set_index="$i"; fi
  done
  [ "$_dc_set_index" -ge 0 ] || { _domain_csv_error "$file" 0 "unknown field $_dc_set_key"; return 1; }
  for ((i = 0; i < _dc_set_keys; i++)); do
    case "${_dc_set_ids[i]}" in
    0[0-9]* | *:0[0-9]*)
      _dc_set_ids[i]="$(_domain_csv_normalize_number "$file" "${CSV_FIELDS[${_dc_set_indexes[i]}]}" "${_dc_set_ids[i]}")" || return 1
      ;;
    esac
    _dc_set_values[_dc_set_indexes[i]]="${_dc_set_ids[i]}"
  done
  case "$_dc_set_value" in
  0[0-9]* | *:0[0-9]*)
    _dc_set_value="$(_domain_csv_normalize_number "$file" "$_dc_set_key" "$_dc_set_value")" || return 1
    ;;
  esac
  csv_read_records "$file" "$header" _domain_csv_set_record "$cardinality" || return 1
  if [ "$_dc_set_found" = false ]; then
    case "${file##*/}" in
    ports.csv | certificates.csv) _domain_csv_error "$file" 0 'cannot update a missing record'; return 1 ;;
    esac
    _dc_set_values[_dc_set_index]="$_dc_set_value"
    _dc_set_rows+=("$(csv_join_row "${_dc_set_values[@]}")")
  fi
  make_temp_for_file temporary "$file" || return 1
  if ! { printf '%s\n' "$header" && printf '%s\n' "${_dc_set_rows[@]}"; } >"$temporary"; then rm -f "$temporary"; return 1; fi
  finalize_temp_file "$file" "$temporary"
}

function _domain_csv_set_record() {
  local file="$1"
  shift 2
  local i=0 matched=true
  local -a values=("$@")
  _domain_csv_normalize_record_numbers "$file" || return 1
  for ((i = 0; i < _dc_set_keys; i++)); do
    [ "${values[${_dc_set_indexes[i]}]}" = "${_dc_set_ids[i]}" ] || matched=false
  done
  if [ "$matched" = true ]; then
    [ "$_dc_set_found" = false ] || return 1
    values[_dc_set_index]="$_dc_set_value"; _dc_set_found=true
  fi
  _dc_set_rows+=("$(csv_join_row "${values[@]}")")
}

# Structural identity checks also run during migration of invalid drafts: two
# records for the same entity cannot be transposed into one unambiguous record.
function _domain_csv_check_record_identity() {
  local file="$1" line="$2" filename="${1##*/}" primary="" secondary="" identity=""
  shift 2
  case "$filename" in
  ports.csv) primary="$(csv_join_row "$1" "$3")" ;;
  # Header spelling is not identity. Value-aware validation accepts identical
  # variants without discarding the original editable records.
  headers.csv) return 0 ;;
  port_options.csv | security_conditions.csv) primary="$(csv_join_row "$1" "$2")" ;;
  paths.csv) primary="$1"; secondary="$(csv_join_row "$2" "$3")" ;;
  security_rules.csv | acl.csv) primary="$1"; secondary="$2" ;;
  docker_options.csv | certificates.csv | path_options.csv | certificate_options.csv) primary="$1" ;;
  nginx_directives.csv) primary="$(csv_join_row "$1" "$2" "$3" "$5")" ;;
  *) return 0 ;;
  esac
  for identity in "primary:$primary" "secondary:$secondary"; do
    [ "$identity" != secondary: ] || continue
    case "$_dc_record_seen" in *$'\n'"$identity"$'\n'*) _domain_csv_error "$file" "$line" 'duplicate logical record'; return 1 ;; esac
    _dc_record_seen="${_dc_record_seen}${identity}"$'\n'
  done
}
