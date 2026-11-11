# shellcheck shell=bash

# Validate data before publishing loaded settings or using them as render tokens.
# Diagnostics name the setting, never its value (which may contain credentials).
function validate_persisted_setting() {
  local key="${1:-}" value="${2-}" token="" valid=false
  case "$key" in
  ENABLE_AUTO_BACKUPS | ENABLE_BACKUP_COMPRESSION)
    case "$value" in true | false) valid=true ;; esac
    ;;
  BACKUP_RETENTION) [[ "$value" =~ ^[0-9]+$ ]] && valid=true ;;
  HTTP_VERSION) is_valid_http_version "$value" && valid=true ;;
  CLIENT_IP_HEADER | PROXY_IP_HEADER)
    if [ -z "$value" ] || is_valid_header_name "$value"; then valid=true; fi
    ;;
  TLS_PROTOCOLS)
    # Preserve harmless list whitespace without glob expansion. Newlines cannot
    # occur within the line-oriented persisted CSV representation.
    local remaining="${value//$'\t'/ }" saw_protocol=false
    valid=true
    while [ -n "$remaining" ]; do
      token="${remaining%% *}"
      case "$token" in
      TLSv1 | TLSv1.1 | TLSv1.2 | TLSv1.3) saw_protocol=true ;;
      "") ;;
      *) valid=false ;;
      esac
      if [ "$remaining" = "$token" ]; then break; fi
      remaining="${remaining#* }"
    done
    [ "$saw_protocol" = true ] || valid=false
    ;;
  TLS_CIPHERS)
    # Preserve the operator's cipher policy; the TLS renderer checks OpenSSL
    # semantics separately. These characters can escape the Nginx directive.
    if [ -n "$value" ] && ! [[ "$value" =~ [[:cntrl:]] ]]; then
      case "$value" in *';'* | *'{'* | *'}'*) ;; *) valid=true ;; esac
    fi
    ;;
  SECURITY_RULE_STATUS | ACL_STATUS) is_status_code "$value" && valid=true ;;
  ACL_POLICY) case "$value" in allow | deny) valid=true ;; esac ;;
  TRUSTED_PROXY_RANGES) validate_trusted_proxy_ranges "$value" >/dev/null 2>&1 && valid=true ;;
  REAL_IP_RECURSIVE | NGINX_DIRECTIVE_STRICT) is_on_off "$value" && valid=true ;;
  VISIBILITY_POLICY) is_valid_visibility_policy "$value" && valid=true ;;
  NGINX_IMAGE | CERTBOT_IMAGE) is_valid_image_ref "$value" && valid=true ;;
  NGINX_PULL_MODE | CERTBOT_PULL_MODE) is_valid_pull_mode "$value" && valid=true ;;
  NGINX_DOCKER_OPTS)
    if [ -z "$value" ]; then
      valid=true
    else
      if ! declare -F normalize_docker_opts_for_storage >/dev/null 2>&1; then
        local backend_helpers=""
        backend_helpers="$(cd "$(dirname "${BASH_SOURCE[0]}")/../backends" && pwd)" || return 1
        # shellcheck source=../backends/_parse_docker_opts_to_lines.sh
        source "$backend_helpers/_parse_docker_opts_to_lines.sh" || return 1
        # shellcheck source=../backends/validate_docker_opts.sh
        source "$backend_helpers/validate_docker_opts.sh" || return 1
      fi
      normalize_docker_opts_for_storage "$value" "saved Nginx options" nginx >/dev/null 2>&1 && valid=true
    fi
    ;;
  *)
    echo "[Error] Unknown persisted setting key." >&2
    return 1
    ;;
  esac
  if [ "$valid" != true ]; then
    echo "[Error] Invalid persisted setting ${key}." >&2
    return 1
  fi
}

function validate_loaded_settings() {
  local key=""
  for key in ENABLE_AUTO_BACKUPS BACKUP_RETENTION ENABLE_BACKUP_COMPRESSION \
    HTTP_VERSION CLIENT_IP_HEADER PROXY_IP_HEADER TLS_PROTOCOLS TLS_CIPHERS \
    SECURITY_RULE_STATUS ACL_STATUS ACL_POLICY TRUSTED_PROXY_RANGES \
    REAL_IP_RECURSIVE NGINX_DIRECTIVE_STRICT NGINX_DOCKER_OPTS VISIBILITY_POLICY \
    NGINX_IMAGE CERTBOT_IMAGE NGINX_PULL_MODE CERTBOT_PULL_MODE; do
    validate_persisted_setting "$key" "${!key-}" || return 1
  done
}

function _persisted_settings_require_header() {
  local file="${1:-}" expected="${2:-}" header=""
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "[Error] Persisted settings file is not a readable regular file: ${file}" >&2
    return 1
  fi
  IFS= read -r header <"$file" || true
  header="${header%$'\r'}"
  if [ "$header" != "$expected" ]; then
    echo "[Error] Invalid persisted settings header in ${file}." >&2
    return 1
  fi
}

# A sentinel preserves trailing newlines through command substitution. The type
# prefix also detects removal, creation, or replacement with a symlink mid-render.
function _persisted_settings_read_snapshot() {
  local file="${1:-}" type=file
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s' missing.
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "[Error] Persisted settings file is not a readable regular file: ${file}" >&2
    return 1
  fi
  [ ! -L "$file" ] || type=symlink
  printf '%s\n' "$type"
  cat <"$file" || return 1
  printf '.'
}

function _persisted_settings_cache_in_scope() {
  local caller=""
  for caller in "${FUNCNAME[@]}"; do
    [ "$caller" != _with_validated_render_settings ] || return 0
  done
  return 1
}

function _persisted_settings_cache_store() {
  _persisted_settings_cache_in_scope || return 0
  _persisted_cache_files[$_persisted_cache_count]="$1"
  _persisted_cache_headers[$_persisted_cache_count]="$2"
  _persisted_cache_settings[$_persisted_cache_count]="$3"
  _persisted_cache_snapshots[$_persisted_cache_count]="$4"
  _persisted_cache_rows[$_persisted_cache_count]="$5"
  _persisted_cache_count=$((_persisted_cache_count + 1))
}

# Return 2 for a cache miss, 1 for a changed/unreadable file, and 0 for a hit.
# Only the wrapper's local arrays can activate caching; environment variables
# cannot authorize skipping validation in a standalone getter.
function _persisted_settings_cache_get() {
  local file="$1" header="$2" setting="$3" output_name="$4"
  local index=0 current=""
  _persisted_settings_cache_in_scope || return 2
  [ "${_persisted_cache_ready:-false}" = true ] || return 2
  while [ "$index" -lt "$_persisted_cache_count" ]; do
    if [ "${_persisted_cache_files[$index]}" = "$file" ] &&
      [ "${_persisted_cache_headers[$index]}" = "$header" ] &&
      [ "${_persisted_cache_settings[$index]}" = "$setting" ]; then
      current="$(_persisted_settings_read_snapshot "$file")" || return 1
      if [ "$current" != "${_persisted_cache_snapshots[$index]}" ]; then
        echo "[Error] Persisted settings changed during config generation: ${file}" >&2
        return 1
      fi
      printf -v "$output_name" '%s' "${_persisted_cache_rows[$index]}"
      return 0
    fi
    index=$((index + 1))
  done
  return 2
}

function _persisted_settings_lookup_row() {
  local rows="${1-}" key="${2-}" domain="" value=""
  # Values are already parsed and normalized. A builtin scan avoids both
  # per-row subprocesses and costly wildcard prefix removal on long strings.
  while IFS=, read -r domain value; do
    if [ "$domain" = "$key" ]; then
      printf '%s\n' "$value"
      return 0
    fi
  done <<<"$rows"
  return 0
}

function _rollback_failed_render_transaction() {
  if declare -F transaction_is_active >/dev/null 2>&1 && transaction_is_active; then
    if [ "${TRANSACTION_MODE:-exit}" = return ]; then
      transaction_return_failure || true
    else
      _rollback_handler
    fi
  fi
}

# Indexed arrays and dynamic local scope work in Bash 3 and survive nested
# command substitutions. A failed preflight never invokes the render callback,
# and every later render starts with new arrays, including after rollback.
function _with_validated_render_settings() {
  local -a _persisted_cache_files=() _persisted_cache_headers=()
  local -a _persisted_cache_settings=() _persisted_cache_snapshots=() _persisted_cache_rows=()
  local _persisted_cache_count=0 _persisted_cache_ready=false render_status=0
  if ! validate_settings_for_render; then
    # Interactive dispatch suppresses errexit in its callers. Exit-mode
    # mutations must stop here, just like later renderer validation failures,
    # so an unchecked caller cannot continue to commit after a failed preflight.
    # Library return-mode callers explicitly propagate this failure instead.
    _rollback_failed_render_transaction
    return 1
  fi
  _persisted_cache_ready=true
  # Keep this command outside a conditional so ordinary CLI callers retain
  # errexit. Conditional/interactive callers still need explicit rollback when
  # a render guard returns without invoking the transaction's ERR trap.
  "$@"
  render_status=$?
  if [ "$render_status" -ne 0 ]; then
    _rollback_failed_render_transaction
  fi
  return "$render_status"
}

function validate_backend_setting_file() {
  local file="${1:-}" header="${2:-}" setting="${3:-}" output_name="${4:-}"
  local line="" line_no=0 domain="" value="" seen=$'\n' rows="" snapshot="" contents=""
  snapshot="$(_persisted_settings_read_snapshot "$file")" || return 1
  if [ "$snapshot" != missing. ]; then
    contents="${snapshot#*$'\n'}"
    contents="${contents%.}"
    line="${contents%%$'\n'*}"
    if [ "${line%$'\r'}" != "$header" ]; then
      echo "[Error] Invalid persisted settings header in ${file}." >&2
      return 1
    fi
    # Validate the captured contents themselves, never a second live-file read.
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      if ! csv_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne 2 ]; then
        echo "[Error] Invalid persisted settings row in ${file} at line ${line_no}." >&2
        return 1
      fi
      domain="${CSV_FIELDS[0]}"
      value="${CSV_FIELDS[1]}"
      if ! is_valid_domain "$domain"; then
        echo "[Error] Invalid persisted settings domain in ${file} at line ${line_no}." >&2
        return 1
      fi
      domain="$(normalize_domain "$domain")" || return 1
      case "$seen" in *$'\n'"$domain"$'\n'*)
        echo "[Error] Duplicate persisted settings domain in ${file} at line ${line_no}." >&2
        return 1 ;;
      esac
      seen+="${domain}"$'\n'
      validate_persisted_setting "$setting" "$value" || return 1
      # Empty stored header overrides explicitly disable forwarding, unlike
      # an absent row. Keep that distinction in both cached and direct lookups.
      if [ -z "$value" ]; then
        case "$setting" in CLIENT_IP_HEADER | PROXY_IP_HEADER) value=off ;; esac
      fi
      rows+="${domain},${value}"$'\n'
    done < <(printf '%s' "$contents")
  fi
  _persisted_settings_cache_store "$file" "$header" "$setting" "$snapshot" "$rows"
  if [ -n "$output_name" ]; then printf -v "$output_name" '%s' "$rows"; fi
}

function validate_backend_setting_files() {
  validate_backend_setting_file "${BACKEND_HTTP_FILE:-}" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" HTTP_VERSION || return 1
  validate_backend_setting_file "${BACKEND_CLIENT_IP_HEADER_FILE:-}" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" CLIENT_IP_HEADER || return 1
  validate_backend_setting_file "${BACKEND_PROXY_IP_HEADER_FILE:-}" "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" PROXY_IP_HEADER || return 1
  validate_backend_setting_file "${BACKEND_ACL_POLICY_FILE:-}" "$STATE_BACKEND_ACL_POLICIES_HEADER" ACL_POLICY || return 1
  validate_backend_setting_file "${BACKEND_ACL_STATUS_FILE:-}" "$STATE_BACKEND_ACL_STATUSES_HEADER" ACL_STATUS || return 1
  validate_backend_setting_file "${BACKEND_SECURITY_RULE_STATUS_FILE:-}" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" SECURITY_RULE_STATUS || return 1
}

function validate_settings_for_render() {
  validate_loaded_settings || return 1
  validate_backend_setting_files || return 1
  validate_dedicated_host_inheritance_state || return 1
}

# A private restore snapshot can be checked without changing live globals or
# creating missing CSV files. Missing optional files retain their usual defaults.
function validate_persisted_config_dir() {
  (
    local CONFIG_DIR="${1:-}"
    local GLOBAL_SETTINGS_FILE="${CONFIG_DIR}/global_settings.csv"
    local BACKEND_HTTP_FILE="${CONFIG_DIR}/backend_http_versions.csv"
    local BACKEND_CLIENT_IP_HEADER_FILE="${CONFIG_DIR}/backend_client_ip_headers.csv"
    local BACKEND_PROXY_IP_HEADER_FILE="${CONFIG_DIR}/backend_proxy_ip_headers.csv"
    local BACKEND_ACL_POLICY_FILE="${CONFIG_DIR}/backend_acl_policies.csv"
    local BACKEND_ACL_STATUS_FILE="${CONFIG_DIR}/backend_acl_statuses.csv"
    local BACKEND_SECURITY_RULE_STATUS_FILE="${CONFIG_DIR}/backend_security_rule_statuses.csv"
    if [ -e "$GLOBAL_SETTINGS_FILE" ] || [ -L "$GLOBAL_SETTINGS_FILE" ]; then
      load_config || return 1
    fi
    validate_settings_for_render
  )
}
