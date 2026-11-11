# shellcheck shell=bash

function _domain_config_legacy_table_domains() {
  local file="$1" header="$2" columns="$3" owner_column="$4" kind="${5:-domain}" line="" n=0 domain="" owns_hostname=false
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  [ ! -L "$file" ] || { _domain_csv_error "$file" 0 'legacy table must not be a symlink'; return 1; }
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -s "$file" ] || { _domain_csv_error "$file" 1 "expected header $header"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" -eq 1 ]; then
      [ "${line%$'\r'}" = "$header" ] || { _domain_csv_error "$file" "$n" "expected header $header"; return 1; }
      continue
    fi
    csv_parse_line "$line" || { _domain_csv_error "$file" "$n" "$CSV_PARSE_ERROR"; return 1; }
    [ "$CSV_FIELD_COUNT" -eq "$columns" ] || { _domain_csv_error "$file" "$n" "expected $columns columns"; return 1; }
    domain="${CSV_FIELDS[owner_column]}"
    owns_hostname=false
    case "$kind" in
    ports)
      case "${CSV_FIELDS[0]}" in backend | port | path) ;; *) _domain_csv_error "$file" "$n" 'unknown backend/port record type'; return 1 ;; esac
      [ "${CSV_FIELDS[0]}" != backend ] || owns_hostname=true
      ;;
    aliases)
      case "${CSV_FIELDS[0]}" in alias | dedicated) ;; *) _domain_csv_error "$file" "$n" 'unknown hostname record type'; return 1 ;; esac
      owns_hostname=true
      ;;
    docker)
      # Migration stages this table into the current domain-keyed layout first.
      # Historical backend:<domain> keys are decoded only by its legacy adapter.
      _domain_config_validate_name "$domain" || { _domain_csv_error "$file" "$n" 'invalid backend Docker options domain'; return 1; }
      ;;
    directives)
      case "${CSV_FIELDS[0]}" in
      global | stream-global)
        [ -z "$domain" ] && [ -z "${CSV_FIELDS[2]}${CSV_FIELDS[3]}" ] || {
          _domain_csv_error "$file" "$n" 'global directive must not have a domain, port, or path'; return 1;
        }
        continue
        ;;
      backend | port | path | stream-backend | stream-port) ;;
      *) _domain_csv_error "$file" "$n" 'unknown directive scope'; return 1 ;;
      esac
      ;;
    esac
    _domain_config_validate_name "$domain" || { _domain_csv_error "$file" "$n" 'missing or invalid domain owner'; return 1; }
    if [ "$owns_hostname" = true ]; then
      case "${_dc_legacy_hostname_owners:-$'\n'}" in
      *$'\n'"$domain"$'\n'*) _domain_csv_error "$file" "$n" "duplicate backend or hostname ownership for $domain"; return 1 ;;
      esac
      _dc_legacy_hostname_owners="${_dc_legacy_hostname_owners:-$'\n'}${domain}"$'\n'
    fi
    printf '%s\n' "$domain"
  done <"$file"
}

function _domain_config_legacy_domains_unsorted() {
  local path="" name="" _dc_legacy_hostname_owners=$'\n'
  _domain_config_legacy_table_domains "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" "$STATE_BACKEND_PORTS_COLS" 1 ports || return 1
  _domain_config_legacy_table_domains "$BACKEND_ALIASES_FILE" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" 1 aliases || return 1
  _domain_config_legacy_table_domains "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" 2 0 || return 1
  _domain_config_legacy_table_domains "$CONFIG_DIR/dedicated_host_inheritance.csv" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 6 0 || return 1
  _domain_config_legacy_table_domains "$BACKEND_DOCKER_OPTS_FILE" "$STATE_BACKEND_DOCKER_OPTS_HEADER" 2 0 docker || return 1
  _domain_config_legacy_table_domains "$SECURITY_RULES_FILE" "$STATE_SECURITY_RULES_HEADER" "$STATE_SECURITY_RULES_COLS" 1 || return 1
  _domain_config_legacy_table_domains "$SECURITY_IP_RULES_FILE" "$STATE_SECURITY_IP_RULES_HEADER" "$STATE_SECURITY_IP_RULES_COLS" 1 || return 1
  _domain_config_legacy_table_domains "$NGINX_DIRECTIVES_FILE" "$STATE_NGINX_DIRECTIVES_HEADER" 7 1 directives || return 1
  for path in "$CERTS_DIR"/*/live/*; do
    [ -d "$path" ] || continue
    name="${path##*/}"; name="${name%_*}"
    is_valid_domain "$name" && printf '%s\n' "$(normalize_domain "$name")"
  done
  for path in "$CERTS_DIR"/mtls/*; do
    [ -d "$path" ] || continue
    name="${path##*/}"
    is_valid_domain "$name" || return 1
    printf '%s\n' "$(normalize_domain "$name")"
  done
  for path in "$(domain_config_root)"/*/certs/*; do
    [ -d "$path" ] || continue
    name="${path%/certs/*}"; name="${name##*/}"
    is_valid_domain "$name" && printf '%s\n' "$name"
  done
}

function _domain_config_legacy_domains() {
  local names=""
  names="$(_domain_config_legacy_domains_unsorted)" || return 1
  [ -z "$names" ] || printf '%s\n' "$names" | LC_ALL=C sort -u
}

function _domain_config_details_validate_row() {
  local file="$1" line="$2" domain="$3" image="$4" state="$5"
  : "$file" "$line"
  _domain_config_validate_name "$domain" || return 1
  case "$_dc_details_seen" in *$'\n'"$domain"$'\n'*) _domain_config_error "Duplicate backend details for $domain."; return 1 ;; esac
  _dc_details_seen+="$domain"$'\n'
  is_valid_image_ref "$image" || return 1
  case "$state" in running | stopped) ;; *) return 1 ;; esac
}

function _domain_config_details_validate() {
  local file="${1:-}" _dc_details_seen=$'\n'
  [ -n "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || { _domain_config_error "Backend details must be a regular CSV file."; return 1; }
  csv_read_records "$file" 'domain,image,state' _domain_config_details_validate_row table
}

function _domain_config_export_tree() {
  local tree="${1:-}" details="${2:-}" domain="" names=""
  names="$(_domain_config_legacy_domains)" || return 1
  mkdir -p "$tree" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    _domain_config_validate_name "$domain" || return 1
    domain_config_export_domain "$domain" "$tree/$domain/config" "$details" || return 1
  done <<<"$names"
}
