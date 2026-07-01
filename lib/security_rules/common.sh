# shellcheck shell=bash
#
# security_rules.sh — Unified, data‑driven security rules (1–10 conditions)

SECURITY_RULES_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Support direct sourcing of lib/security_rules.sh or this common helper before
# lib/config.sh has initialized the runtime paths.
if [ -z "${BASE_DIR:-}" ]; then
  BASE_DIR="$(cd "${SECURITY_RULES_COMMON_DIR}/../.." && pwd)"
fi

: "${STATE_DIR:=${BASE_DIR}/state}"
: "${CONFIG_DIR:=${STATE_DIR}/config}"
: "${NGINX_CONFIG_DIR:=${CONFIG_DIR}/nginx_conf}"
: "${NGINX_HTTP_CONF_DIR:=${NGINX_CONFIG_DIR}/conf.d}"
: "${NGINX_STREAM_CONF_DIR:=${NGINX_CONFIG_DIR}/stream_conf}"
: "${SECURITY_RULES_FILE:=${CONFIG_DIR}/security_rules.csv}"
: "${SECURITY_IP_RULES_FILE:=${CONFIG_DIR}/security_ip_rules.csv}"
: "${SECURITY_IP_DIR:=${NGINX_HTTP_CONF_DIR}/security_ip}"
: "${SECURITY_IP_STREAM_DIR:=${NGINX_STREAM_CONF_DIR}/security_ip}"

# Files
: "${SECURITY_RULES_DB:=${SECURITY_RULES_FILE}}"                     # state/config/security_rules.csv
: "${SECURITY_RULES_INC:=${NGINX_HTTP_CONF_DIR}/security_rules.inc}" # generated include
: "${SECURITY_IP_RULES_DB:=${SECURITY_IP_RULES_FILE}}"               # state/config/security_ip_rules.csv

# Internal generator state for generated security-rule variables (reset per include build)
SR_RULE_COUNTER=0
SR_RULE_VARS_EMITTED=""

# Supported condition keywords (global superset; UI and validators will
# restrict this per selector type below)
# shellcheck disable=SC2034  # exported to CLI picker
SECURITY_RULE_CONDITIONS=(
  equals not_equals
  contains not_contains
  starts_with not_starts_with
  ends_with not_ends_with
  matches not_matches
  in not_in
  gt ge lt le
  exists not_exists
)

# Validate a security rule value to prevent nginx config injection.
# Reject values containing control characters (including newlines) which can
# break generated nginx config syntax.
function _sr_validate_value() {
  local val="${1:-}"
  [ -z "$val" ] && return 0

  # Reject control characters including newlines
  if [[ "$val" =~ [[:cntrl:]] ]]; then
    echo "[Error] Security rule value cannot contain control characters" >&2
    return 1
  fi

  return 0
}

function _sr_trim_whitespace() {
  local val="${1:-}"
  val="$(printf '%s' "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  printf '%s' "$val"
}

function _security_rules_restore_force_recreate_flag() {
  local previous_force="${1:-__dockistrate_unset__}"

  if [ "$previous_force" = "__dockistrate_unset__" ]; then
    unset DOCKISTRATE_FORCE_NGINX_RECREATE
  else
    DOCKISTRATE_FORCE_NGINX_RECREATE="$previous_force"
  fi
}

function _security_rules_restore_ready_check_flag() {
  local previous_ready="${1:-__dockistrate_unset__}"

  if [ "$previous_ready" = "__dockistrate_unset__" ]; then
    unset DOCKISTRATE_SECURITY_NGINX_READY_CHECK
  else
    DOCKISTRATE_SECURITY_NGINX_READY_CHECK="$previous_ready"
  fi
}

function update_nginx_config_for_security_change() {
  local previous_force="${DOCKISTRATE_FORCE_NGINX_RECREATE-__dockistrate_unset__}"
  local previous_ready="${DOCKISTRATE_SECURITY_NGINX_READY_CHECK-__dockistrate_unset__}"
  local update_deferred=false
  DOCKISTRATE_FORCE_NGINX_RECREATE=true
  if [ "${SKIP_UPDATE_NGINX_CONFIG:-}" = "true" ]; then
    DOCKISTRATE_DEFERRED_SECURITY_NGINX_RECREATE=true
    update_deferred=true
  else
    DOCKISTRATE_SECURITY_NGINX_READY_CHECK=true
  fi

  if ! update_nginx_config; then
    _security_rules_restore_force_recreate_flag "$previous_force"
    _security_rules_restore_ready_check_flag "$previous_ready"
    return 1
  fi
  _security_rules_restore_force_recreate_flag "$previous_force"
  _security_rules_restore_ready_check_flag "$previous_ready"
  [ "$update_deferred" = true ] && return 0
  return 0
}

function _sr_validate_condition_parts() {
  local index="${1:-}" src="${2:-}" name="${3:-}" cond="${4:-}" value="${5:-}"
  local context="Condition ${index}"
  local src_trimmed name_trimmed cond_trimmed value_trimmed src_lc

  src_trimmed="$(_sr_trim_whitespace "$src")"
  name_trimmed="$(_sr_trim_whitespace "$name")"
  cond_trimmed="$(_sr_trim_whitespace "$cond")"
  value_trimmed="$(_sr_trim_whitespace "$value")"

  if [ -z "$src_trimmed" ]; then
    echo "[Error] ${context}: source cannot be empty." >&2
    return 1
  fi

  if [ -z "$cond_trimmed" ]; then
    echo "[Error] ${context}: condition cannot be empty." >&2
    return 1
  fi

  src_lc="$(printf '%s' "$src_trimmed" | tr '[:upper:]' '[:lower:]')"
  case "$src_lc" in
  header | cookie | arg | var)
    if [ -z "$name_trimmed" ] || [ "$name_trimmed" = "-" ]; then
      echo "[Error] ${context}: source '${src_lc}' requires a non-empty name." >&2
      return 1
    fi
    ;;
  esac

  case "$cond_trimmed" in
  exists | not_exists) ;;
  *)
    if [ -z "$value_trimmed" ]; then
      echo "[Error] ${context}: value cannot be empty for condition '${cond_trimmed}'." >&2
      return 1
    fi
    ;;
  esac

  return 0
}

function _sr_is_header_selector_name() {
  local name="${1:-}"
  if declare -F is_valid_header_name >/dev/null 2>&1; then
    is_valid_header_name "$name"
    return $?
  fi
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

function _sr_is_simple_selector_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]]
}

function _sr_is_nginx_variable_name() {
  local name="${1:-}"
  name="${name#\$}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

function _sr_validate_selector_name() {
  local selector="${1:-}" context="${2:-}"
  local name="" label=""

  case "$selector" in
  header:*)
    name="${selector#header:}"
    label="header"
    if _sr_is_header_selector_name "$name"; then
      return 0
    fi
    ;;
  cookie:*)
    name="${selector#cookie:}"
    label="cookie"
    if _sr_is_simple_selector_name "$name"; then
      return 0
    fi
    ;;
  arg:*)
    name="${selector#arg:}"
    label="arg"
    if _sr_is_simple_selector_name "$name"; then
      return 0
    fi
    ;;
  var:*)
    name="${selector#var:}"
    label="var"
    if _sr_is_nginx_variable_name "$name"; then
      return 0
    fi
    ;;
  *)
    return 0
    ;;
  esac

  if [ -n "$context" ]; then
    echo "[Error] ${context}: invalid ${label} selector name '${name}'." >&2
  else
    echo "[Error] Invalid ${label} selector name '${name}'." >&2
  fi
  return 1
}

function _sr_is_cidr_token() {
  local token
  token="$(_sr_trim_whitespace "${1:-}")"
  [ -n "$token" ] || return 1
  is_valid_cidr "$token"
}

function _sr_validate_acl_cidr_deny_status() {
  local scope="${1:-}" action="${2:-}" ip="${3:-}" code="${4:-}"
  if [ "$scope" = "l7" ] && [ "$action" = "deny" ] && [ -n "$code" ] && [ "$code" != "403" ] && _sr_is_cidr_token "$ip"; then
    echo "[Error] CIDR L7 deny rules always return 403; use status 403 or an exact IP for custom status: $ip" >&2
    return 1
  fi
  return 0
}

function _sr_is_ip_selector() {
  local selector="${1:-}"
  case "$selector" in
  ip | ip:l7 | ip:l3)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

function _sr_value_list_contains_cidr() {
  local raw="${1:-}"
  local normalized="${raw//|/,}"
  local -a tokens=()
  local token
  IFS=',' read -r -a tokens <<<"$normalized"
  for token in "${tokens[@]}"; do
    token="$(_sr_trim_whitespace "$token")"
    [ -z "$token" ] && continue
    if _sr_is_cidr_token "$token"; then
      return 0
    fi
  done
  return 1
}

function _sr_validate_ip_selector_value() {
  local selector="${1:-}" cond="${2:-}" value="${3:-}" context="${4:-}"
  _sr_is_ip_selector "$selector" || return 0
  case "$cond" in
  equals | not_equals)
    if _sr_is_cidr_token "$value"; then
      if [ -n "$context" ]; then
        echo "[Error] ${context}: CIDR values are not supported for '${selector}' with condition '${cond}'." >&2
      else
        echo "[Error] CIDR values are not supported for '${selector}' with condition '${cond}'." >&2
      fi
      return 1
    fi
    ;;
  in | not_in)
    if _sr_value_list_contains_cidr "$value"; then
      if [ -n "$context" ]; then
        echo "[Error] ${context}: CIDR values are not supported for '${selector}' with condition '${cond}'." >&2
      else
        echo "[Error] CIDR values are not supported for '${selector}' with condition '${cond}'." >&2
      fi
      return 1
    fi
    ;;
  esac
  return 0
}

function _sr_is_regex_condition() {
  local cond="${1:-}"
  case "$cond" in
  matches | not_matches)
    return 0
    ;;
  *)
    return 1
    ;;
  esac
}

function _sr_has_regex_validator() {
  local grep_status=0

  if command -v pcre2grep >/dev/null 2>&1; then
    return 0
  fi

  printf '' | grep -P '' >/dev/null 2>&1
  grep_status=$?
  if [ "$grep_status" -eq 0 ] || [ "$grep_status" -eq 1 ]; then
    return 0
  fi

  return 1
}

function _sr_validate_regex_pattern() {
  local pattern="${1:-}" context="${2:-}" # input-validation-audit: ignore
  # Intentional user-supplied regex for matches/not_matches; compile-validated below via pcre2grep/grep -P.
  local err_prefix="[Error] Invalid regex pattern"
  local grep_status=0

  if [ -n "$context" ]; then
    err_prefix="[Error] ${context}: invalid regex pattern"
  fi

  # Regex rejection is best-effort only: keep validating when a compatible
  # checker exists, but don't require extra packages on minimal Linux/macOS.
  _sr_has_regex_validator || return 0

  if command -v pcre2grep >/dev/null 2>&1; then
    printf '' | pcre2grep -Mi -- "$pattern" >/dev/null 2>&1
    grep_status=$?
    if [ "$grep_status" -eq 0 ] || [ "$grep_status" -eq 1 ]; then
      return 0
    fi
    echo "${err_prefix}: ${pattern}" >&2
    return 1
  fi

  printf '' | grep -P -- "$pattern" >/dev/null 2>&1
  grep_status=$?
  if [ "$grep_status" -eq 0 ] || [ "$grep_status" -eq 1 ]; then
    return 0
  fi

  echo "${err_prefix}: ${pattern}" >&2
  return 1
}

function _sr_validate_rule_triplet() {
  local selector="${1:-}" cond="${2:-}" value="${3:-}" context="${4:-}"

  _sr_validate_selector_name "$selector" "$context" || return 1
  _sr_validate_selector_condition "$selector" "$cond" || return 1

  if [[ "$cond" != "exists" && "$cond" != "not_exists" ]]; then
    _sr_validate_value "$value" || return 1
    _sr_validate_ip_selector_value "$selector" "$cond" "$value" "$context" || return 1
    if [[ "$cond" == "in" || "$cond" == "not_in" ]] &&
      declare -F _sr_exact_list_regex >/dev/null 2>&1 &&
      ! _sr_exact_list_regex "$value" >/dev/null; then
      if [ -n "$context" ]; then
        echo "[Error] ${context}: list conditions require non-empty comma- or pipe-separated values." >&2
      else
        echo "[Error] List conditions require non-empty comma- or pipe-separated values." >&2
      fi
      return 1
    fi
    if _sr_is_regex_condition "$cond"; then
      _sr_validate_regex_pattern "$value" "$context" || return 1
    fi
  fi

  if [[ "$cond" =~ ^(gt|ge|lt|le)$ ]]; then
    if [[ ! "$selector" =~ ^var: ]]; then
      echo "[Error] Numeric operators (gt/ge/lt/le) are only allowed with 'var:<name>' selectors." >&2
      return 1
    fi
    if ! _sr_is_unsigned_int "$value"; then
      echo "[Error] Numeric comparisons require an integer value (got '$value')." >&2
      return 1
    fi
  fi

  return 0
}

function _sr_acl_duplicate_error() {
  local domain="${1:-}" scope="${2:-}" action="${3:-}" ip="${4:-}" code="${5:-}"
  local code_suffix=""
  [ -n "$code" ] && code_suffix=" code=${code}"
  echo "[Error] ACL rule already exists for ${domain}: scope=${scope} action=${action} ip=${ip}${code_suffix}" >&2
}

function _sr_acl_rule_exists() {
  local domain="${1:-}" scope="${2:-}" action="${3:-}" ip="${4:-}" code="${5:-}" skip_id="${6:-}"
  local line="" line_no=0 row_id=0

  domain="$(normalize_domain "$domain")"
  [ -f "$SECURITY_IP_RULES_DB" ] || return 1
  csv_require_header "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
    row_id=$((row_id + 1))
    if [ -n "$skip_id" ] && [ "$row_id" -eq "$skip_id" ]; then
      continue
    fi

    local rule_domain rule_scope rule_action rule_ip rule_code
    rule_domain="$(normalize_domain "${CSV_FIELDS[1]-}")"
    rule_scope="${CSV_FIELDS[2]-}"
    rule_action="${CSV_FIELDS[3]-}"
    rule_ip="${CSV_FIELDS[4]-}"
    rule_code="${CSV_FIELDS[5]-}"

    if [ "$rule_domain" = "$domain" ] && [ "$rule_scope" = "$scope" ] && [ "$rule_action" = "$action" ] && [ "$rule_ip" = "$ip" ] && [ "$rule_code" = "$code" ]; then
      return 0
    fi
  done <"$SECURITY_IP_RULES_DB"

  return 1
}

function _sr_require_unique_acl_rule() {
  local domain="${1:-}" scope="${2:-}" action="${3:-}" ip="${4:-}" code="${5:-}" skip_id="${6:-}"
  if _sr_acl_rule_exists "$domain" "$scope" "$action" "$ip" "$code" "$skip_id"; then
    _sr_acl_duplicate_error "$domain" "$scope" "$action" "$ip" "$code"
    return 1
  fi
  return 0
}

function _sr_domain_has_any_acl_rows() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  [ -f "$SECURITY_IP_RULES_DB" ] || return 1

  local enabled d scope action ip code line="" line_no=0
  if ! csv_require_header "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER"; then
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
    enabled="${CSV_FIELDS[0]-}"
    d="${CSV_FIELDS[1]-}"
    scope="${CSV_FIELDS[2]-}"
    action="${CSV_FIELDS[3]-}"
    ip="${CSV_FIELDS[4]-}"
    code="${CSV_FIELDS[5]-}"
    [ "$enabled" = "enabled" ] && continue
    [ "$enabled" = "1" ] || continue
    [ -z "$d" ] && continue
    d="$(normalize_domain "$d")"
    if [ "$d" = "$domain" ]; then
      return 0
    fi
  done <"$SECURITY_IP_RULES_DB"

  return 1
}

function _sr_domain_has_direct_allow_cidr() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  [ -f "$SECURITY_IP_RULES_DB" ] || return 1

  local enabled d scope action ip code line="" line_no=0
  if ! csv_require_header "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER"; then
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
    enabled="${CSV_FIELDS[0]-}"
    d="${CSV_FIELDS[1]-}"
    scope="${CSV_FIELDS[2]-}"
    action="${CSV_FIELDS[3]-}"
    ip="${CSV_FIELDS[4]-}"
    code="${CSV_FIELDS[5]-}"
    [ "$enabled" = "enabled" ] && continue
    [ "$enabled" = "1" ] || continue
    [ -z "$d" ] && continue
    d="$(normalize_domain "$d")"
    [ "$d" = "$domain" ] || continue
    [ "$action" = "allow" ] || continue
    if _sr_is_cidr_token "$ip"; then
      return 0
    fi
  done <"$SECURITY_IP_RULES_DB"

  return 1
}

function _sr_domain_has_effective_allow_cidr() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  if _sr_domain_has_direct_allow_cidr "$domain"; then
    return 0
  fi

  local target_domain
  target_domain="$(backend_for_dedicated_host "$domain")"
  [ -n "$target_domain" ] || return 1

  if command -v should_inherit_acl >/dev/null 2>&1; then
    should_inherit_acl "$domain" || return 1
  fi

  # Dedicated host inheritance is all-or-nothing for ACL rows.
  if _sr_domain_has_any_acl_rows "$domain"; then
    return 1
  fi

  _sr_domain_has_direct_allow_cidr "$target_domain"
}

function _sr_list_acl_domains() {
  {
    if [ -f "$BACKEND_PORTS_FILE" ]; then
      local bp_line="" bp_line_no=0
      while IFS= read -r bp_line || [ -n "$bp_line" ]; do
        bp_line_no=$((bp_line_no + 1))
        [ "$bp_line_no" -eq 1 ] && continue
        state_backend_ports_parse_line "$bp_line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
        [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
        printf '%s\n' "$(normalize_domain "${STATE_BP_DOMAIN:-}")"
      done <"$BACKEND_PORTS_FILE"
    fi

    local aliases_file
    aliases_file="$(backend_aliases_file)"
    if [ -f "$aliases_file" ]; then
      local alias_line="" alias_line_no=0
      while IFS= read -r alias_line || [ -n "$alias_line" ]; do
        alias_line_no=$((alias_line_no + 1))
        [ "$alias_line_no" -eq 1 ] && continue
        csv_parse_line "$alias_line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || continue
        case "${CSV_FIELDS[0]-}" in
        alias | dedicated)
          printf '%s\n' "$(normalize_domain "${CSV_FIELDS[1]-}")"
          ;;
        esac
      done <"$aliases_file"
    fi

    if [ -f "$SECURITY_IP_RULES_DB" ]; then
      local sec_line="" sec_line_no=0
      while IFS= read -r sec_line || [ -n "$sec_line" ]; do
        sec_line_no=$((sec_line_no + 1))
        [ "$sec_line_no" -eq 1 ] && continue
        csv_parse_line "$sec_line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
        [ "${CSV_FIELDS[0]-}" = "1" ] || continue
        printf '%s\n' "$(normalize_domain "${CSV_FIELDS[1]-}")"
      done <"$SECURITY_IP_RULES_DB"
    fi
  } | awk 'NF > 0' | sort -u
}

function _sr_effective_acl_policy() {
  local domain="${1:-}" global_policy="${2:-${ACL_POLICY:-deny}}"
  local old_policy="${ACL_POLICY:-}" policy

  ACL_POLICY="$global_policy"
  policy="$(get_backend_acl_policy "$domain")"
  ACL_POLICY="$old_policy"

  printf '%s' "$policy"
}

function _sr_effective_acl_status() {
  local domain="${1:-}" global_status="${2:-${ACL_STATUS:-403}}"
  local old_status="${ACL_STATUS:-}" status

  ACL_STATUS="$global_status"
  status="$(get_backend_acl_status "$domain")"
  ACL_STATUS="$old_status"

  printf '%s' "$status"
}

function _sr_validate_acl_cidr_mode_for_domain() {
  local domain="${1:-}" effective_policy="${2:-}" effective_status="${3:-}"
  domain="$(normalize_domain "$domain")"

  if ! _sr_domain_has_effective_allow_cidr "$domain"; then
    return 0
  fi

  if [ "$effective_policy" = "deny" ] && [ "$effective_status" != "403" ]; then
    echo "[Error] ACL deny mode with CIDR allow rules requires status 403 (domain: ${domain}, status: ${effective_status})." >&2
    echo "[Hint] Use status 403, convert CIDR allow rules to exact IPs, or remove CIDR allow rules." >&2
    return 1
  fi

  return 0
}

function _sr_has_backend_acl_policy_override() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  state_csv_has_row_by_keys "$BACKEND_ACL_POLICY_FILE" "$STATE_BACKEND_ACL_POLICIES_HEADER" "$STATE_BACKEND_ACL_POLICIES_COLS" 1 "$domain"
}

function _sr_has_backend_acl_status_override() {
  local domain="${1:-}"
  domain="$(normalize_domain "$domain")"
  state_csv_has_row_by_keys "$BACKEND_ACL_STATUS_FILE" "$STATE_BACKEND_ACL_STATUSES_HEADER" "$STATE_BACKEND_ACL_STATUSES_COLS" 1 "$domain"
}

function _sr_list_inheriting_dedicated_hosts_for_backend() {
  local backend_domain="${1:-}" host
  backend_domain="$(normalize_domain "$backend_domain")"

  local dedicated_hosts
  dedicated_hosts="$(list_dedicated_hosts_for_backend "$backend_domain")"
  [ -n "$dedicated_hosts" ] || return 0

  while IFS= read -r host; do
    [ -z "$host" ] && continue
    host="$(normalize_domain "$host")"
    if command -v should_inherit_acl >/dev/null 2>&1; then
      should_inherit_acl "$host" || continue
    fi
    printf '%s\n' "$host"
  done <<<"$dedicated_hosts" | awk 'NF > 0' | sort -u
}

function _sr_validate_backend_acl_policy_transition() {
  local backend_domain="${1:-}" new_policy="${2:-}" global_status="${3:-${ACL_STATUS:-403}}"
  backend_domain="$(normalize_domain "$backend_domain")"

  local effective_status
  effective_status="$(_sr_effective_acl_status "$backend_domain" "$global_status")"
  _sr_validate_acl_cidr_mode_for_domain "$backend_domain" "$new_policy" "$effective_status" || return 1

  local host
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    # Dedicated hosts with explicit policy do not inherit backend policy updates.
    if _sr_has_backend_acl_policy_override "$host"; then
      continue
    fi
    effective_status="$(_sr_effective_acl_status "$host" "$global_status")"
    _sr_validate_acl_cidr_mode_for_domain "$host" "$new_policy" "$effective_status" || return 1
  done <<<"$(_sr_list_inheriting_dedicated_hosts_for_backend "$backend_domain")"

  return 0
}

function _sr_validate_backend_acl_status_transition() {
  local backend_domain="${1:-}" new_status="${2:-}" global_policy="${3:-${ACL_POLICY:-deny}}"
  backend_domain="$(normalize_domain "$backend_domain")"

  local effective_policy
  effective_policy="$(_sr_effective_acl_policy "$backend_domain" "$global_policy")"
  _sr_validate_acl_cidr_mode_for_domain "$backend_domain" "$effective_policy" "$new_status" || return 1

  local host
  while IFS= read -r host; do
    [ -z "$host" ] && continue
    # Dedicated hosts with explicit status do not inherit backend status updates.
    if _sr_has_backend_acl_status_override "$host"; then
      continue
    fi
    effective_policy="$(_sr_effective_acl_policy "$host" "$global_policy")"
    _sr_validate_acl_cidr_mode_for_domain "$host" "$effective_policy" "$new_status" || return 1
  done <<<"$(_sr_list_inheriting_dedicated_hosts_for_backend "$backend_domain")"

  return 0
}

function _sr_validate_acl_cidr_mode_all_domains() {
  local global_policy="${1:-${ACL_POLICY:-deny}}" global_status="${2:-${ACL_STATUS:-403}}"
  local domains domain policy status

  domains="$(_sr_list_acl_domains)"
  [ -n "$domains" ] || return 0

  while IFS= read -r domain; do
    [ -z "$domain" ] && continue
    policy="$(_sr_effective_acl_policy "$domain" "$global_policy")"
    status="$(_sr_effective_acl_status "$domain" "$global_status")"
    _sr_validate_acl_cidr_mode_for_domain "$domain" "$policy" "$status" || return 1
  done <<<"$domains"

  return 0
}

function __dockistrate_security_rules_common_loaded() {
  :
}
