# shellcheck shell=bash

# Normalize numeric meaning in memory without rewriting editable files. Keep an
# invalid value intact so validation can report it and backups can retain an
# unfinished draft. Certificate IDs/suffix labels remain storage identities.
function _domain_csv_normalize_number() {
  local filename="${1##*/}" field="$2" value="$3"
  case "$filename:$field" in
  backend.csv:container_port | ports.csv:listen_port | ports.csv:upstream_port | \
    port_options.csv:listen_port | paths.csv:listen_port | nginx_directives.csv:listen_port)
    if is_valid_port "$value"; then normalize_port "$value"; return; fi
    ;;
  paths.csv:priority)
    if is_valid_path_priority "$value"; then normalize_positive_decimal "$value"; return; fi
    ;;
  paths.csv:target)
    if is_valid_path_target "$value"; then normalize_path_target "$value"; return; fi
    ;;
  ports.csv:redirect_code | port_options.csv:redirect_code | path_options.csv:redirect_code)
    if is_valid_redirect_code_spec "$value"; then normalize_redirect_code_spec "$value"; return; fi
    ;;
  esac
  printf '%s' "$value"
}

# The record reader/setter supplies its local values array and canonical named
# headers. Avoid spawning a shell per cell in unrelated CSV files.
function _domain_csv_normalize_record_numbers() {
  local numeric_file="$1" numeric_index=0
  case "${numeric_file##*/}" in
  backend.csv | ports.csv | port_options.csv | paths.csv | path_options.csv | nginx_directives.csv)
    for ((numeric_index = 0; numeric_index < ${#values[@]}; numeric_index++)); do
      case "${CSV_RECORD_HEADERS[numeric_index]}" in
      container_port | listen_port | upstream_port | priority | target | redirect_code)
        case "${values[numeric_index]}" in
        0[0-9]* | *:0[0-9]*)
          values[numeric_index]="$(_domain_csv_normalize_number "$numeric_file" "${CSV_RECORD_HEADERS[numeric_index]}" "${values[numeric_index]}")" || return 1
          ;;
        esac
        ;;
      esac
    done
    ;;
  esac
}
