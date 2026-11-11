# shellcheck shell=bash
# shellcheck disable=SC2034

# Action is appended to the aggregate format: old field offsets never change.
# Only staged migration/intake calls this codec; normal reads remain strict.
function _domain_security_convert_aggregate() {
  local source="$1" _dc_security_destination="$2" header=""
  local _dc_security_legacy=false
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  IFS= read -r header <"$source" || return 1
  csv_parse_line "$header" || return 1
  case "$CSV_FIELD_COUNT" in
  47) header="$STATE_SECURITY_RULES_LEGACY_HEADER"; _dc_security_legacy=true ;;
  48) header="${STATE_SECURITY_RULES_LEGACY_HEADER},action" ;;
  *) _domain_csv_error "$source" 1 'unsupported security-rule aggregate header'; return 1 ;;
  esac
  printf '%s\n' "${STATE_SECURITY_RULES_LEGACY_HEADER},action" >"$_dc_security_destination" || return 1
  csv_read_records "$source" "$header" _domain_security_convert_aggregate_row table
}

function _domain_security_convert_aggregate_row() {
  shift 2
  local action=""
  if [ "$_dc_security_legacy" = true ]; then
    csv_join_row "$@" require >>"$_dc_security_destination"
  else
    local -a fields=("$@")
    action="$(_sr_normalize_action "${fields[47]:-}")" || return 1
    fields[47]="$action"
    csv_join_row "${fields[@]}" >>"$_dc_security_destination"
  fi
}

function _domain_csv_convert_directory() (
  local version="$1" source="$2" destination="$3" layout="${4:-flat}" intermediate=""
  local DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  case "$version" in
  2 | 3)
    intermediate="${destination}.schema4"
    _domain_csv_convert_to_v4_directory "$version" "$source" "$intermediate" || return 1
    _domain_csv_convert_v4_directory "$intermediate" "$destination" flat || return 1
    rm -rf "$intermediate"
    ;;
  4) _domain_csv_convert_v4_directory "$source" "$destination" "$layout" ;;
  *) _domain_config_error "Unsupported domain conversion source: $version"; return 1 ;;
  esac
)

# Schema4 drafts may include saved notes/unfinished files which its backups
# already preserve. Copy that safe tree first, then convert only known records.
# Accepted snapshots retain the strict flat inventory and record contract.
function _domain_csv_convert_v4_directory() {
  local source="$1" _dc_action_destination="$2" layout="${3:-flat}" file="" filename="" header=""
  local _dc_record_seen=$'\n' _dc_action_legacy=false DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ "$source" != "$_dc_action_destination" ] || return 1
  case "$layout" in
  flat) _domain_config_copy_inputs "$source" "$_dc_action_destination" || return 1 ;;
  tree) _domain_config_draft_tree_copy "$source" "$_dc_action_destination" || return 1 ;;
  *) return 1 ;;
  esac
  for file in "$source"/* "$source"/.[!.]* "$source"/..?*; do
    [ -e "$file" ] || continue
    filename="${file##*/}"
    if [ "$layout" = tree ]; then
      [ -f "$file" ] || continue
      case "$filename" in domain.csv | security_rules.csv) ;; *) continue ;; esac
    fi
    case "$filename" in
    domain.csv | security_rules.csv)
      _domain_csv_write_header "$_dc_action_destination/$filename" || return 1
      _dc_record_seen=$'\n'; _dc_action_legacy=false
      if [ "$filename" = security_rules.csv ]; then
        IFS= read -r header <"$file" || return 1
        csv_parse_line "$header" || return 1
        case "$CSV_FIELD_COUNT" in
        7) header=rule_id,order,enabled,mode,status_code,reason,source_location; _dc_action_legacy=true ;;
        8) header="$DOMAIN_CSV_HEADER" ;;
        *) _domain_csv_error "$file" 1 'unsupported security-rule header'; return 1 ;;
        esac
      else
        header="$DOMAIN_CSV_HEADER"
      fi
      csv_read_records "$file" "$header" _domain_csv_convert_action_record "$DOMAIN_CSV_CARDINALITY" || return 1
      ;;
    *)
      # Validate structural identities without rewriting other declarations.
      _domain_csv_schema "$filename" || return 1
      _dc_record_seen=$'\n'
      csv_read_records "$file" "$DOMAIN_CSV_HEADER" _domain_csv_check_record_identity "$DOMAIN_CSV_CARDINALITY" || return 1
      ;;
    esac
  done
}

function _domain_csv_convert_action_record() {
  local filename="${1##*/}"
  _domain_csv_check_record_identity "$@" || return 1
  shift 2
  case "$filename" in
  domain.csv)
    case "$1" in 4 | 5) shift; set -- 5 "$@" ;; *) _domain_csv_error "$filename" 0 'unsupported domain schema'; return 1 ;; esac
    ;;
  security_rules.csv)
    if [ "$_dc_action_legacy" = true ]; then
      set -- "$1" "$2" "$3" require "$4" "$5" "$6" "$7"
    else
      # Preserve incomplete draft values; normal validation rejects an unknown
      # nonempty action later, but its existing bytes must not be discarded.
      set -- "$1" "$2" "$3" "${4:-require}" "$5" "$6" "$7" "$8"
    fi
    ;;
  esac
  csv_join_row "$@" >>"$_dc_action_destination/$filename"
}

function _domain_config_use_input_schema() {
  local version="$1"
  case "$version" in
  1 | 2 | 3) DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=3; DOMAIN_CONFIG_LEGACY_RECOVERY=true ;;
  4) DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=4; DOMAIN_CONFIG_LEGACY_RECOVERY=true ;;
  5) DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5; DOMAIN_CONFIG_LEGACY_RECOVERY=false ;;
  *) return 1 ;;
  esac
  state_security_rules_use_schema "$version"
}
