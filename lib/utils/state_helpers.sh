# shellcheck shell=bash

function backend_aliases_file() {
  local dir="${CONFIG_DIR:-${DEFAULT_STATE_DIR}/config}"
  if [ -n "${BACKEND_ALIASES_FILE:-}" ]; then
    echo "$BACKEND_ALIASES_FILE"
  else
    echo "${dir}/backend_aliases.csv"
  fi
}

: "${BACKEND_ALIASES_FILE:="$(backend_aliases_file)"}"

function _state_backend_ports_for_each_row() {
  local callback="${1:-}"
  local line="" line_no=0
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
    "$callback" "$line_no" || return 1
  done <"$BACKEND_PORTS_FILE"
}

function backend_exists() {
  local d="${1:-}"
  local normalized
  normalized="$(normalize_domain "$d")"
  local line="" line_no=0
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
    if [ "${STATE_BP_RECORD_TYPE}" = "backend" ] && [ "$(normalize_domain "${STATE_BP_DOMAIN}")" = "$normalized" ]; then
      return 0
    fi
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function _state_alias_find_target() {
  local lookup="${1:-}" expected_type="${2:-}"
  local aliases_file line line_no=0
  lookup="$(normalize_domain "$lookup")"
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || return 1
  csv_require_header "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || return 1
    if [ "${CSV_FIELDS[0]}" = "$expected_type" ] && [ "$(normalize_domain "${CSV_FIELDS[1]}")" = "$lookup" ]; then
      printf '%s\n' "$(normalize_domain "${CSV_FIELDS[2]}")"
      return 0
    fi
  done <"$aliases_file"

  return 1
}

function _backend_alias_state_validation_error() {
  local line_no="${1:-0}" reason="${2:-invalid alias state row}"
  echo "[Error] Invalid backend_aliases.csv row at line ${line_no}: ${reason}" >&2
  return 1
}

function validate_backend_aliases_state_for_render() {
  local aliases_file line line_no=0
  local seen_keys=$'\n'
  local seen_hosts=$'\n'
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || return 0
  csv_require_header "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      _backend_alias_state_validation_error "$line_no" "row could not be parsed as CSV (${CSV_PARSE_ERROR})"
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_ALIASES_COLS" ]; then
      _backend_alias_state_validation_error "$line_no" "row has invalid column count (expected ${STATE_BACKEND_ALIASES_COLS}, got ${CSV_FIELD_COUNT})"
      return 1
    fi

    local record_type="${CSV_FIELDS[0]}"
    local hostname="${CSV_FIELDS[1]}"
    local target_domain="${CSV_FIELDS[2]}"
    local normalized_hostname normalized_target key
    normalized_hostname="$(normalize_domain "$hostname")"
    normalized_target="$(normalize_domain "$target_domain")"

    case "$record_type" in
    alias | dedicated) ;;
    "")
      _backend_alias_state_validation_error "$line_no" "row type is empty"
      return 1
      ;;
    *)
      _backend_alias_state_validation_error "$line_no" "unknown row type '${record_type}'"
      return 1
      ;;
    esac

    if ! is_valid_domain "$normalized_hostname"; then
      _backend_alias_state_validation_error "$line_no" "${record_type} hostname '${hostname}' is invalid"
      return 1
    fi
    if ! is_valid_domain "$normalized_target"; then
      _backend_alias_state_validation_error "$line_no" "target domain '${target_domain}' is invalid"
      return 1
    fi
    if ! backend_exists "$normalized_target"; then
      _backend_alias_state_validation_error "$line_no" "target backend domain '${normalized_target}' does not exist"
      return 1
    fi
    if backend_exists "$normalized_hostname"; then
      _backend_alias_state_validation_error "$line_no" "hostname '${normalized_hostname}' conflicts with an existing backend domain"
      return 1
    fi

    key="${record_type}|${normalized_hostname}"
    case "$seen_keys" in
    *$'\n'"${key}"$'\n'*)
      _backend_alias_state_validation_error "$line_no" "duplicate ${record_type} hostname '${normalized_hostname}'"
      return 1
      ;;
    esac
    case "$seen_hosts" in
    *$'\n'"${normalized_hostname}"$'\n'*)
      _backend_alias_state_validation_error "$line_no" "hostname '${normalized_hostname}' is already used by another alias row"
      return 1
      ;;
    esac
    seen_keys="${seen_keys}${key}"$'\n'
    seen_hosts="${seen_hosts}${normalized_hostname}"$'\n'
  done <"$aliases_file"

  return 0
}

function _state_helpers_remove_domain_matches() {
  local candidate="${1:-}" normalized_candidate=""
  [ -n "$candidate" ] || return 1
  normalized_candidate="$(normalize_domain "$candidate")"
  [ "$normalized_candidate" = "$STATE_HELPERS_REMOVE_DOMAIN" ]
}

function _state_helpers_drop_domain_col0_row() {
  if _state_helpers_remove_domain_matches "${CSV_FIELDS[0]-}"; then
    return 10
  fi
  return 0
}

function _state_helpers_drop_domain_col1_row() {
  if _state_helpers_remove_domain_matches "${CSV_FIELDS[1]-}"; then
    return 10
  fi
  return 0
}

function _state_helpers_backend_ports_row_noop() {
  return 0
}

function _state_helpers_validate_backend_ports_readable_for_cleanup() {
  [ -f "${BACKEND_PORTS_FILE:-}" ] || return 0
  if ! _state_backend_ports_for_each_row _state_helpers_backend_ports_row_noop; then
    echo "[Error] Refusing to remove domain-keyed render state because backend_ports.csv is invalid." >&2
    return 1
  fi
  return 0
}

function remove_domain_keyed_render_state() {
  local domain="${1:-}"
  if [ -z "$domain" ]; then
    echo "[Error] remove_domain_keyed_render_state requires a domain." >&2
    return 1
  fi
  domain="$(normalize_domain "$domain")"
  if declare -F backend_exists >/dev/null 2>&1; then
    if ! _state_helpers_validate_backend_ports_readable_for_cleanup; then
      return 1
    fi
    if backend_exists "$domain"; then
      echo "[Error] Refusing to remove domain-keyed render state for '${domain}' because it is an existing backend domain." >&2
      return 1
    fi
  fi

  local STATE_HELPERS_REMOVE_DOMAIN="$domain"

  if [ -f "${BACKEND_HEADERS_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" "$STATE_BACKEND_HEADERS_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_MTLS_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER" "$STATE_BACKEND_MTLS_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_HTTP_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$STATE_BACKEND_HTTP_VERSIONS_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_CLIENT_IP_HEADER_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_CLIENT_IP_HEADER_FILE" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" "$STATE_BACKEND_CLIENT_IP_HEADERS_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_PROXY_IP_HEADER_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_PROXY_IP_HEADER_FILE" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$STATE_BACKEND_PROXY_IP_HEADERS_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_ACL_POLICY_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$STATE_BACKEND_ACL_POLICIES_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_ACL_STATUS_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" "$STATE_BACKEND_ACL_STATUSES_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${BACKEND_SECURITY_RULE_STATUS_FILE:-}" ]; then
    csv_rewrite_rows "$BACKEND_SECURITY_RULE_STATUS_FILE" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" "$STATE_BACKEND_SECURITY_RULE_STATUSES_COLS" _state_helpers_drop_domain_col0_row || return 1
  fi
  if [ -f "${SECURITY_IP_RULES_DB:-${SECURITY_IP_RULES_FILE:-}}" ]; then
    csv_rewrite_rows "${SECURITY_IP_RULES_DB:-${SECURITY_IP_RULES_FILE:-}}" "$STATE_SECURITY_IP_RULES_HEADER" "$STATE_SECURITY_IP_RULES_COLS" _state_helpers_drop_domain_col1_row || return 1
  fi
  if [ -f "${SECURITY_RULES_DB:-${SECURITY_RULES_FILE:-}}" ]; then
    csv_rewrite_rows "${SECURITY_RULES_DB:-${SECURITY_RULES_FILE:-}}" "$STATE_SECURITY_RULES_HEADER" "$STATE_SECURITY_RULES_COLS" _state_helpers_drop_domain_col1_row || return 1
  fi

  if declare -F nginx_directives_state_remove_for_domain >/dev/null 2>&1; then
    nginx_directives_state_remove_for_domain "$domain" >/dev/null || return 1
  fi
}

function alias_exists() {
  local alias="${1:-}"
  local normalized
  normalized="$(normalize_domain "$alias")"
  local target=""
  target="$(_state_alias_find_target "$normalized" "alias" || true)"
  [ -n "$target" ]
}

function backend_for_alias() {
  local alias="${1:-}"
  local target=""
  target="$(_state_alias_find_target "$alias" "alias" || true)"
  if [ -n "$target" ] && backend_exists "$target"; then
    echo "$target"
  fi
}

function backend_for_dedicated_host() {
  local hostname="${1:-}"
  local target=""
  target="$(_state_alias_find_target "$hostname" "dedicated" || true)"
  if [ -n "$target" ] && backend_exists "$target"; then
    echo "$target"
  fi
}

function primary_domain_for() {
  local candidate="${1:-}"
  local normalized
  normalized="$(normalize_domain "$candidate")"
  local aliased_domain
  aliased_domain="$(backend_for_alias "$normalized")"
  if [ -n "$aliased_domain" ]; then
    echo "$aliased_domain"
    return
  fi
  local dedicated_domain
  dedicated_domain="$(backend_for_dedicated_host "$normalized")"
  if [ -n "$dedicated_domain" ]; then
    echo "$dedicated_domain"
    return
  fi
  echo "$normalized"
}

function domain_exists() {
  local d="${1:-}"
  local normalized
  normalized="$(normalize_domain "$d")"
  backend_exists "$normalized" && return 0
  local target
  target="$(backend_for_alias "$normalized")"
  [ -n "$target" ] && return 0
  target="$(backend_for_dedicated_host "$normalized")"
  [ -n "$target" ]
}

function list_domain_aliases() {
  local domain="${1:-}" aliases_file line line_no=0
  domain="$(normalize_domain "$domain")"
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || return 0
  csv_require_header "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || return 1
    if [ "${CSV_FIELDS[0]}" = "alias" ] && [ "$(normalize_domain "${CSV_FIELDS[2]}")" = "$domain" ]; then
      printf '%s\n' "$(normalize_domain "${CSV_FIELDS[1]}")"
    fi
  done <"$aliases_file" | sort -u
}

function dedicated_host_exists() {
  local hostname="${1:-}"
  local normalized target
  normalized="$(normalize_domain "$hostname")"
  target="$(_state_alias_find_target "$normalized" "dedicated" || true)"
  [ -n "$target" ]
}

function list_dedicated_hosts_for_backend() {
  local domain="${1:-}" aliases_file line line_no=0
  domain="$(normalize_domain "$domain")"
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || return 0
  csv_require_header "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || return 1
    if [ "${CSV_FIELDS[0]}" = "dedicated" ] && [ "$(normalize_domain "${CSV_FIELDS[2]}")" = "$domain" ]; then
      printf '%s\n' "$(normalize_domain "${CSV_FIELDS[1]}")"
    fi
  done <"$aliases_file" | sort -u
}

function set_dedicated_host_alias() {
  local hostname="${1:-}" target_domain="${2:-}"
  local aliases_file
  hostname="$(normalize_domain "$hostname")"
  target_domain="$(normalize_domain "$target_domain")"
  aliases_file="$(backend_aliases_file)"
  mkdir -p "$(dirname "$aliases_file")"
  state_csv_upsert_row_by_keys \
    "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" 2 \
    "dedicated" "$hostname" \
    -- "dedicated" "$hostname" "$target_domain"
}

function remove_dedicated_host_alias() {
  local hostname="${1:-}" aliases_file
  hostname="$(normalize_domain "$hostname")"
  aliases_file="$(backend_aliases_file)"
  [ -f "$aliases_file" ] || return 0
  state_csv_delete_by_keys "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" 2 "dedicated" "$hostname"
}

# Convert a request header name (e.g. "X-Forwarded-For") to the
# corresponding Nginx variable (e.g. "$http_x_forwarded_for").
function nginx_header_var() {
  local name="${1:-}"
  name="${name//-/_}"
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
  echo "\$http_${name}"
}

function dedicated_host_inheritance_file() {
  state_dedicated_host_inheritance_file
}

function get_dedicated_host_inheritance() {
  local hostname="${1:-}" field="${2:-}"
  local file line line_no=0
  hostname="$(normalize_domain "$hostname")"
  file="$(dedicated_host_inheritance_file)"

  # Default is to inherit everything.
  local default="yes"

  [ -f "$file" ] || {
    echo "$default"
    return 0
  }
  csv_require_header "$file" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" || {
    echo "$default"
    return 0
  }

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      echo "$default"
      return 0
    }
    [ "$CSV_FIELD_COUNT" -eq "$STATE_DEDICATED_HOST_INHERITANCE_COLS" ] || {
      echo "$default"
      return 0
    }
    if [ "$(normalize_domain "${CSV_FIELDS[0]}")" = "$hostname" ]; then
      case "$field" in
      mtls) echo "${CSV_FIELDS[1]}" ;;
      acl) echo "${CSV_FIELDS[2]}" ;;
      security_rules) echo "${CSV_FIELDS[3]}" ;;
      headers) echo "${CSV_FIELDS[4]}" ;;
      paths) echo "${CSV_FIELDS[5]}" ;;
      *) echo "$default" ;;
      esac
      return 0
    fi
  done <"$file"

  echo "$default"
}

function set_dedicated_host_inheritance() {
  local hostname="${1:-}"
  local inherit_mtls="${2:-yes}"
  local inherit_acl="${3:-yes}"
  local inherit_security_rules="${4:-yes}"
  local inherit_headers="${5:-yes}"
  local inherit_paths="${6:-yes}"
  local file

  hostname="$(normalize_domain "$hostname")"
  file="$(dedicated_host_inheritance_file)"
  mkdir -p "$(dirname "$file")"

  state_csv_upsert_row_by_keys \
    "$file" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" "$STATE_DEDICATED_HOST_INHERITANCE_COLS" 1 \
    "$hostname" \
    -- "$hostname" "$inherit_mtls" "$inherit_acl" "$inherit_security_rules" "$inherit_headers" "$inherit_paths"
}

function remove_dedicated_host_inheritance() {
  local hostname="${1:-}" file
  hostname="$(normalize_domain "$hostname")"
  file="$(dedicated_host_inheritance_file)"
  [ -f "$file" ] || return 0
  state_csv_delete_by_keys "$file" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" "$STATE_DEDICATED_HOST_INHERITANCE_COLS" 1 "$hostname"
}

function should_inherit_mtls() {
  local hostname="${1:-}" val
  val="$(get_dedicated_host_inheritance "$hostname" "mtls")"
  [ "$val" = "yes" ]
}

function should_inherit_acl() {
  local hostname="${1:-}" val
  val="$(get_dedicated_host_inheritance "$hostname" "acl")"
  [ "$val" = "yes" ]
}

function should_inherit_security_rules() {
  local hostname="${1:-}" val
  val="$(get_dedicated_host_inheritance "$hostname" "security_rules")"
  [ "$val" = "yes" ]
}

function should_inherit_headers() {
  local hostname="${1:-}" val
  val="$(get_dedicated_host_inheritance "$hostname" "headers")"
  [ "$val" = "yes" ]
}

function should_inherit_paths() {
  local hostname="${1:-}" val
  val="$(get_dedicated_host_inheritance "$hostname" "paths")"
  [ "$val" = "yes" ]
}
