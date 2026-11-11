# shellcheck shell=bash
# The schema-3 codec remains explicit: normal reads never consume split files.
# Conversion is staged and structural, so incomplete draft values survive while
# duplicate identities and orphan option rows fail rather than losing data.
# shellcheck disable=SC2034

function _domain_csv_convert_to_v4_directory() (
  local version="$1" source="$2" destination="$3" intermediate=""
  local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=4
  case "$version" in
  2)
    intermediate="${destination}.schema3"
    (local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3; _domain_csv_convert_v2_directory "$source" "$intermediate") || return 1
    _domain_csv_convert_v3_directory "$intermediate" "$destination" || return 1
    rm -rf "$intermediate"
    ;;
  3) _domain_csv_convert_v3_directory "$source" "$destination" ;;
  *) _domain_config_error "Unsupported domain conversion source: $version"; return 1 ;;
  esac
)

function _domain_csv_convert_v3_directory() {
  local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=4
  local source="$1" _dc_merge_destination="$2" file="" filename="" options="" header="" columns=0
  local _dc_record_seen=$'\n' _dc_merge_kind="" index=0
  local -a _dc_merge_option_keys=() _dc_merge_option_rows=() _dc_merge_option_used=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ "$source" != "$_dc_merge_destination" ] || return 1
  _domain_config_dir_guard "$source" || return 1
  [ ! -L "$_dc_merge_destination" ] || return 1
  (umask 077; mkdir -p "$_dc_merge_destination") || return 1
  for file in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -e "$file" ] || continue
    filename="${file##*/}"
    case "$filename" in port_options.csv | certificate_options.csv) continue ;; esac
    _domain_csv_write_header "$_dc_merge_destination/$filename" || return 1
    _dc_record_seen=$'\n'
    case "$filename" in
    security_rules.csv)
      IFS= read -r header <"$file" || [ -n "$header" ] || return 1
      csv_parse_line "$header" || return 1
      if [ "$CSV_FIELD_COUNT" -eq 8 ]; then
        (local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
          _domain_csv_write_header "$_dc_merge_destination/$filename" || return 1
          csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_merge_current_record table) || return 1
      else
        csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_merge_current_record table || return 1
      fi
      ;;
    ports.csv | certificates.csv)
      _dc_merge_kind="$filename"; _dc_merge_option_keys=(); _dc_merge_option_rows=(); _dc_merge_option_used=()
      if [ "$filename" = ports.csv ]; then
        options="$source/port_options.csv"
        header=listen_port,protocol,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc
      else
        options="$source/certificate_options.csv"
        header=certificate_id,source_fullchain,source_privkey
      fi
      csv_read_records "$options" "$header" _domain_csv_merge_option_record table || return 1
      IFS= read -r header <"$file" || [ -n "$header" ] || return 1
      csv_parse_line "$header" || return 1
      columns="$CSV_FIELD_COUNT"
      if { [ "$filename" = ports.csv ] && [ "$columns" -eq 5 ]; } ||
        { [ "$filename" = certificates.csv ] && [ "$columns" -eq 3 ]; }; then
        header="$(local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3; _domain_csv_schema "$filename" && printf '%s\n' "$DOMAIN_CSV_HEADER")" || return 1
      else
        _domain_csv_schema "$filename" || return 1
        header="$DOMAIN_CSV_HEADER"
      fi
      _dc_record_seen=$'\n'
      csv_read_records "$file" "$header" _domain_csv_merge_entity_record table || return 1
      for ((index = 0; index < ${#_dc_merge_option_keys[@]}; index++)); do
        [ "${_dc_merge_option_used[index]}" = yes ] || {
          _domain_csv_error "$options" 0 "option record has no matching ${filename} record: ${_dc_merge_option_keys[index]}"; return 1;
        }
      done
      ;;
    *) csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_merge_current_record "$DOMAIN_CSV_CARDINALITY" || return 1 ;;
    esac
  done
  # An options table without its owning table can only be empty.
  for filename in port_options.csv certificate_options.csv; do
    file="$source/$filename"; [ -e "$file" ] || continue
    if [ "$filename" = port_options.csv ]; then
      [ ! -e "$source/ports.csv" ] || continue
      header=listen_port,protocol,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc
    else
      [ ! -e "$source/certificates.csv" ] || continue
      header=certificate_id,source_fullchain,source_privkey
    fi
    csv_read_records "$file" "$header" _domain_csv_merge_orphan_record table || return 1
  done
}

function _domain_csv_merge_option_record() {
  local file="$1" line="$2" key="" existing=""
  shift 2
  if [ "$_dc_merge_kind" = ports.csv ]; then key="$(csv_join_row "$1" "$2")"; shift 2
  else key="$(csv_join_row "$1")"; shift; fi
  for existing in "${_dc_merge_option_keys[@]+"${_dc_merge_option_keys[@]}"}"; do
    [ "$existing" != "$key" ] || { _domain_csv_error "$file" "$line" 'duplicate logical option record'; return 1; }
  done
  _dc_merge_option_keys+=("$key")
  _dc_merge_option_rows+=("$(csv_join_row "$@")")
  _dc_merge_option_used+=(no)
}

function _domain_csv_merge_entity_record() {
  local file="$1" line="$2" key="" index=0 found=-1 expected=0
  local -a values=() CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  _domain_csv_check_record_identity "$@" || return 1
  shift 2
  values=("$@")
  if [ "$_dc_merge_kind" = ports.csv ]; then key="$(csv_join_row "$1" "$3")"; expected=5
  else key="$(csv_join_row "$1")"; expected=3; fi
  for ((index = 0; index < ${#_dc_merge_option_keys[@]}; index++)); do
    if [ "${_dc_merge_option_keys[index]}" = "$key" ]; then found="$index"; break; fi
  done
  if [ "$#" -eq "$expected" ]; then
    if [ "$found" -ge 0 ]; then
      csv_parse_line "${_dc_merge_option_rows[found]}" || return 1
      values+=("${CSV_FIELDS[@]}"); _dc_merge_option_used[found]=yes
    elif [ "$_dc_merge_kind" = ports.csv ]; then values+=('' '' '' '' '')
    else values+=('' ''); fi
  elif [ "$found" -ge 0 ]; then
    _domain_csv_error "$file" "$line" 'both merged and split options exist for this record'; return 1
  fi
  csv_join_row "${values[@]}" >>"$_dc_merge_destination/$_dc_merge_kind"
}

function _domain_csv_merge_current_record() {
  local filename="${1##*/}"
  _domain_csv_check_record_identity "$@" || return 1
  shift 2
  if [ "$filename" = domain.csv ]; then
    case "$1" in 2 | 3) shift; set -- 4 "$@" ;; esac
  fi
  csv_join_row "$@" >>"$_dc_merge_destination/$filename"
}

function _domain_csv_merge_orphan_record() {
  _domain_csv_error "$1" "$2" 'option record has no matching owning table'
}
