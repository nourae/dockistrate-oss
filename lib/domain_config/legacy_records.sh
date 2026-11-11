# shellcheck shell=bash
# shellcheck disable=SC2034
# Compatibility codecs are used only by explicit migration and recovery.

# Version-2 input is accepted only by explicit conversion or interrupted legacy
# recovery. Ordinary reads never silently consume the obsolete layout.
function _domain_csv_read_v2() {
  local file="$1" callback="$2" header="" cols=0 line="" line_no=0 key="" seen=$'\n' field="" allowed="" keys=0 i=0
  local _dc_record_callback="$2" _dc_record_keys=-1 _dc_record_seen=$'\n'
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  _domain_csv_schema "${file##*/}" || return 1
  allowed=",$DOMAIN_CSV_HEADER,"; keys="$DOMAIN_CSV_KEYS"
  case "$keys" in
  0) header=key,value; cols=2 ;;
  1) header="${DOMAIN_CSV_HEADER%%,*},key,value"; cols=3 ;;
  2) header=listen_port,protocol,key,value; cols=4 ;;
  *) csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_expand_record; return $? ;;
  esac
  [ ! -L "$file" ] || return 1
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -s "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      [ "${line%$'\r'}" = "$header" ] || { _domain_csv_error "$file" 1 "expected legacy header $header"; return 1; }
      continue
    fi
    csv_parse_line "$line" || { _domain_csv_error "$file" "$line_no" "$CSV_PARSE_ERROR"; return 1; }
    [ "$CSV_FIELD_COUNT" -eq "$cols" ] || return 1
    for field in "${CSV_FIELDS[@]}"; do case "$field" in *$'\r'* | *$'\n'*) return 1 ;; esac; done
    field="${CSV_FIELDS[keys]}"
    case "$allowed" in *",$field,"*) ;; *) _domain_csv_error "$file" "$line_no" "unknown setting $field"; return 1 ;; esac
    key=""
    for ((i = 0; i <= keys; i++)); do key="${key}${CSV_FIELDS[i]}"$'\t'; done
    case "$seen" in *$'\n'"$key"$'\n'*) _domain_csv_error "$file" "$line_no" 'duplicate logical row'; return 1 ;; esac
    seen="${seen}${key}"$'\n'
    "$callback" "$file" "$line_no" "${CSV_FIELDS[@]}" || return 1
  done <"$file"
}

function _domain_csv_convert_v2_row() {
  local filename="${1##*/}" file="$1" line_no="$2" keys=0 key="" value="" i=0
  shift 2
  local -a args=("$@")
  _domain_csv_schema "$filename" || return 1
  keys="$DOMAIN_CSV_KEYS"
  if [ "$keys" -lt 0 ]; then csv_join_row "$@" >>"$_dc_v2_destination/$filename"; return $?; fi
  key="${args[keys]}"; value="${args[keys + 1]}"
  case "$filename:$key:$value" in
  domain.csv:schema_version:2) args[keys + 1]=3 ;;
  settings.csv:client_ip_header: | settings.csv:proxy_ip_header:) args[keys + 1]=off ;;
  backend.csv:network: | backend.csv:state: | settings.csv:*: | inheritance.csv:*: | mtls.csv:enabled: | port_options.csv:websocket: | port_options.csv:redirect_enabled: | port_options.csv:http3_enabled: | port_options.csv:alt_svc: | path_options.csv:websocket: | path_options.csv:redirect_enabled:)
    _domain_csv_error "$file" "$line_no" "empty $key cannot preserve its legacy meaning; correct it before migration"; return 1 ;;
  esac
  _domain_csv_set "$_dc_v2_destination/$filename" "${args[@]}"
}

function _domain_csv_convert_v2_directory() {
  local source="$1" _dc_v2_destination="$2" file="" filename="" header="" _dc_record_seen=$'\n'
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ "$source" != "$_dc_v2_destination" ] || return 1
  _domain_config_dir_guard "$source" || return 1
  [ ! -L "$_dc_v2_destination" ] || return 1
  (umask 077; mkdir -p "$_dc_v2_destination") || return 1
  for file in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -e "$file" ] || continue
    filename="${file##*/}"
    case "$filename" in
    security_rules.csv)
      IFS= read -r header <"$file" || [ -n "$header" ] || return 1
      csv_parse_line "$header" || return 1
      if [ "$CSV_FIELD_COUNT" -eq 8 ]; then
        # An editor may retain a converted draft after migration rollback.
        (local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
          _domain_csv_write_header "$_dc_v2_destination/$filename" || return 1
          _dc_record_seen=$'\n'
          csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_convert_current_record "$DOMAIN_CSV_CARDINALITY") || return 1
        continue
      fi
      ;;
    ports.csv | certificates.csv)
      IFS= read -r header <"$file" || [ -n "$header" ] || return 1
      csv_parse_line "$header" || return 1
      if { [ "$filename" = ports.csv ] && [ "$CSV_FIELD_COUNT" -eq 10 ]; } ||
        { [ "$filename" = certificates.csv ] && [ "$CSV_FIELD_COUNT" -eq 5 ]; }; then
        (local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=4
          _domain_csv_write_header "$_dc_v2_destination/$filename" || return 1
          _dc_record_seen=$'\n'
          csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_convert_current_record "$DOMAIN_CSV_CARDINALITY") || return 1
        continue
      fi
      ;;
    esac
    _domain_csv_write_header "$_dc_v2_destination/$filename" || return 1
    IFS= read -r header <"$file" || [ -n "$header" ] || return 1
    case "${header%$'\r'}" in
    key,value | listen_port,protocol,key,value | path_id,key,value | certificate_id,key,value)
      _domain_csv_read_v2 "$file" _domain_csv_convert_v2_row || return 1 ;;
    *)
      # A rolled-back migration may retain an editor's changes to already
      # converted files. Their blanks have current semantics, not legacy ones.
      _dc_record_seen=$'\n'
      csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_convert_current_record "$DOMAIN_CSV_CARDINALITY" || return 1 ;;
    esac
  done
}

function _domain_csv_convert_current_record() {
  _domain_csv_check_record_identity "$@" || return 1
  local filename="${1##*/}"
  shift 2
  csv_join_row "$@" >>"$_dc_v2_destination/$filename"
}
