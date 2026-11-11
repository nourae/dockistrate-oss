# shellcheck shell=bash
if ! declare -F normalize_decimal_number >/dev/null 2>&1; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/numbers.sh"
fi

function normalize_domain() {
  local raw="${1:-}"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]'
}

function sanitize_domain_name() {
  local raw="${1:-}"
  echo "$raw" | sed 's/[^a-zA-Z0-9\.\-]/-/g'
}

# Domain name: letters/digits/hyphens with dots, TLD >= 2
function is_valid_domain() {
  local d
  d="$(normalize_domain "${1:-}")"
  [[ -n "$d" ]] || return 1
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

function is_valid_port() {
  normalize_port "${1:-}" >/dev/null
}

# Accepts empty (treated as default elsewhere) or a valid port number
function is_valid_optional_port() {
  local p="${1:-}"
  # Empty is allowed to let callers apply their own default (e.g., 443)
  [ -z "$p" ] && return 0
  is_valid_port "$p"
}

function is_valid_protocol() { case "${1:-}" in http | https | tcp | udp) return 0 ;; *) return 1 ;; esac }

function validate_http_port_combination() {
  local protocol="${1:-}" listen_port="${2:-}"
  listen_port="$(normalize_port "$listen_port")" || return 1
  if [ "$protocol" = "http" ] && [ "$listen_port" = "443" ]; then
    echo "[Error] HTTP protocol is not allowed on port 443. Use HTTPS for port 443." >&2
    return 1
  fi
  return 0
}

function is_valid_network_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]]
}

function is_valid_redirect_code_spec() {
  local spec="${1:-}" code="" target_port=""
  [[ -n "$spec" ]] || return 1

  if [[ "$spec" == *:* ]]; then
    code="${spec%%:*}"
    target_port="${spec#*:}"
    [[ -n "$target_port" ]] || return 1
    is_valid_port "$target_port" || return 1
  else
    code="$spec"
  fi

  case "$code" in
  301 | 302 | 308) return 0 ;;
  esac
  return 1
}

function is_valid_http_version() { case "${1:-}" in http1.0 | http1.1 | http2) return 0 ;; *) return 1 ;; esac }

function is_valid_http3_flag() {
  case "${1:-}" in
  on | off) return 0 ;;
  *) return 1 ;;
  esac
}

function is_valid_alt_svc_mode() {
  local value="${1:-}"
  if [ -z "$value" ]; then
    return 1
  fi
  case "$value" in
  auto | off) return 0 ;;
  esac
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  case "$value" in
  *"{"* | *"}"*)
    return 1
    ;;
  esac
  return 0
}

function is_valid_path_match_mode() {
  case "${1:-}" in
  prefix | exact | regex) return 0 ;;
  *) return 1 ;;
  esac
}

function is_valid_path_priority() {
  normalize_positive_decimal "${1:-}" >/dev/null
}

function is_valid_path_target() {
  local value="${1:-}"
  [ -z "$value" ] && return 0
  if is_valid_port "$value"; then
    return 0
  fi
  if [[ "$value" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]]; then
    local target_port="${value##*:}"
    is_valid_port "$target_port"
    return $?
  fi
  return 1
}

function normalize_path_target() {
  local value="${1:-}" port=""
  [ -n "$value" ] || return 0
  if [[ "$value" == *:* ]]; then
    is_valid_path_target "$value" || return 1
    port="$(normalize_port "${value##*:}")" || return 1
    printf '%s:%s' "${value%:*}" "$port"
  else
    normalize_port "$value"
  fi
}

function normalize_redirect_code_spec() {
  local value="${1:-}" port=""
  is_valid_redirect_code_spec "$value" || return 1
  if [[ "$value" == *:* ]]; then
    port="$(normalize_port "${value#*:}")" || return 1
    printf '%s:%s' "${value%%:*}" "$port"
  else
    printf '%s' "$value"
  fi
}

function is_valid_path_rewrite_spec() {
  local value="${1:-}"
  case "$value" in
  none | strip-prefix) return 0 ;;
  replace:/*)
    local replacement="${value#replace:}"
    if declare -F is_valid_path_prefix >/dev/null 2>&1; then
      is_valid_path_prefix "$replacement"
      return $?
    fi
    return 0
    ;;
  esac
  return 1
}

function is_valid_reason_value() {
  local value="${1:-}"
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  case "$value" in
  *";"* | *"{"* | *"}"* | *'$'*)
    return 1
    ;;
  esac
  return 0
}

function is_valid_loc_value() {
  local value="${1:-}"
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  case "$value" in
  *";"* | *"{"* | *"}"* | *'$'*)
    return 1
    ;;
  esac
  return 0
}

# Conservative header name validation: token of letters, digits, and hyphens
function is_valid_header_name() {
  local n="${1:-}"
  [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]
}

# Reject control characters that could break generated configs.
function is_valid_header_value() {
  local value="${1:-}"
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    return 1
  fi
  return 0
}

function is_header_or_off() {
  local v="${1:-}"
  [ "$v" = "off" ] && return 0
  is_valid_header_name "$v"
}

function is_status_code() {
  local c="${1:-}"
  [[ "$c" =~ ^[1-5][0-9]{2}$ ]]
}

function is_yes_no() { case "${1:-}" in yes | no) return 0 ;; *) return 1 ;; esac }

function is_on_off() { case "${1:-}" in on | off) return 0 ;; *) return 1 ;; esac }

function is_true_false() { case "${1:-}" in true | false) return 0 ;; *) return 1 ;; esac }

function is_valid_pull_mode() { case "${1:-}" in always | if-missing | never) return 0 ;; *) return 1 ;; esac }

function is_valid_visibility_policy() { case "${1:-}" in full | redacted) return 0 ;; *) return 1 ;; esac }

# IP address validation (IPv4 only)
function is_valid_ipv4() {
  local ip="${1:-}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.'
  local o1 o2 o3 o4
  read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    ((o >= 0 && o <= 255)) || return 1
  done
  return 0
}

function is_valid_cidr() {
  local s="${1:-}"
  [[ "$s" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}\/(3[0-2]|[12]?[0-9])$ ]] || return 1
  is_valid_ipv4 "${s%/*}"
}

function is_valid_ip_or_cidr() {
  local v="${1:-}"
  is_valid_ipv4 "$v" || is_valid_cidr "$v"
}

function validate_trusted_proxy_ranges() {
  local ranges="${1:-}" token=""
  for token in $ranges; do
    if ! is_valid_ip_or_cidr "$token"; then
      echo "[Error] Invalid trusted proxy range in persisted global settings: ${token}" >&2
      return 1
    fi
  done
  return 0
}

# Docker image reference syntax, including registry ports, IPv6, tags and digests.
# Keep the match anchored to the entire input: splitting path components with
# read would silently ignore a newline and the rest of a persisted value.
function is_valid_image_ref() {
  local ref="${1:-}"
  local path_component='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
  local domain_component='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
  local host="${domain_component}(\.${domain_component})*|\[[A-Fa-f0-9:]+\]"
  local name="((${host})(:[0-9]+)?/)?${path_component}(/${path_component})*"
  local tag='[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}'
  local digest='[A-Za-z][A-Za-z0-9]*([-_+.][A-Za-z][A-Za-z0-9]*)*:[A-Fa-f0-9]{32,}'
  local reference="^${name}(:${tag})?(@${digest})?$"
  [[ "$ref" =~ $reference ]]
}

function require_valid_image_ref() {
  local image="${1:-}" label="${2:-image}"
  if ! is_valid_image_ref "$image"; then
    echo "[Error] Invalid Docker image reference for ${label}." >&2
    return 1
  fi
}

# Validate shell variable names used for indirect assignments.
function is_valid_var_name() {
  local name="${1:-}"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

function require_valid_var_name() {
  local name="${1:-}"
  if ! is_valid_var_name "$name"; then
    echo "[Error] Invalid output variable name: $name" >&2
    return 1
  fi
}

function require_valid_domain() {
  local domain="${1:-}"
  local return_mode="${2:-}"
  if ! is_valid_domain "$domain"; then
    echo "[Error] Invalid domain: $domain" >&2
    if [ -n "$return_mode" ]; then
      return 1
    fi
    exit 1
  fi
}

function require_valid_port() {
  local port="${1:-}"
  local return_mode="${2:-}"
  if ! is_valid_port "$port"; then
    echo "[Error] Invalid port: $port" >&2
    if [ -n "$return_mode" ]; then
      return 1
    fi
    exit 1
  fi
}

function normalize_validated_value() {
  local validator="${1:-}" value="${2:-}"
  case "$validator" in
  is_valid_domain)
    value="$(normalize_domain "$value")"
    ;;
  is_valid_port | is_valid_optional_port)
    [ -z "$value" ] || value="$(normalize_port "$value")" || return 1
    ;;
  esac
  printf '%s' "$value"
}
