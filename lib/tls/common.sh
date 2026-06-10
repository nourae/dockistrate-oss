# shellcheck shell=bash


function _validate_tls_ciphers() {
  local str="$1"
  openssl ciphers "$str" >/dev/null 2>&1 || {
    echo "[Error] Invalid cipher string" >&2
    return 1
  }
}


function _validate_tls_protocols() {
  local prot
  for prot in "$@"; do
    case "$prot" in
    TLSv1 | TLSv1.1 | TLSv1.2 | TLSv1.3) ;;
    *)
      echo "[Error] Invalid TLS protocol: $prot" >&2
      return 1
      ;;
    esac
  done
}


function _tls_render_validation_error() {
  local source="${1:-TLS settings}" line_no="${2:-0}" reason="${3:-invalid TLS value}"
  if [ "$line_no" -gt 0 ] 2>/dev/null; then
    echo "[Error] Invalid ${source} at line ${line_no}: ${reason}" >&2
  else
    echo "[Error] Invalid ${source}: ${reason}" >&2
  fi
  return 1
}


function _validate_tls_protocol_string_for_render() {
  local protocols="${1:-}" source="${2:-TLS protocols}" line_no="${3:-0}"
  local noglob_was_set=0
  if [ -z "$protocols" ]; then
    _tls_render_validation_error "$source" "$line_no" "protocol list cannot be empty"
    return 1
  fi
  case "$-" in
  *f*) noglob_was_set=1 ;;
  *) set -f ;;
  esac
  set -- $protocols
  if [ "$noglob_was_set" -eq 0 ]; then
    set +f
  fi
  if [ "$#" -eq 0 ]; then
    _tls_render_validation_error "$source" "$line_no" "protocol list cannot be empty"
    return 1
  fi
  if ! _validate_tls_protocols "$@"; then
    _tls_render_validation_error "$source" "$line_no" "protocol list '${protocols}' is invalid"
    return 1
  fi
  return 0
}


function _validate_tls_cipher_string_for_render() {
  local ciphers="${1:-}" source="${2:-TLS ciphers}" line_no="${3:-0}"
  if [ -z "$ciphers" ]; then
    _tls_render_validation_error "$source" "$line_no" "cipher string cannot be empty"
    return 1
  fi
  if [[ "$ciphers" =~ [[:cntrl:]] ]]; then
    _tls_render_validation_error "$source" "$line_no" "cipher string cannot contain control characters"
    return 1
  fi
  case "$ciphers" in
  *";"* | *"{"* | *"}"*)
    _tls_render_validation_error "$source" "$line_no" "cipher string contains unsafe Nginx directive characters"
    return 1
    ;;
  esac
  if _tls_cipher_validator_available && ! _validate_tls_ciphers "$ciphers"; then
    _tls_render_validation_error "$source" "$line_no" "cipher string is invalid"
    return 1
  fi
  return 0
}


function _tls_cipher_validator_available() {
  command -v openssl >/dev/null 2>&1 || return 1
  openssl ciphers >/dev/null 2>&1
}


function _validate_port_tls_file_for_render() {
  local file="${1:-}" header="${2:-}" kind="${3:-}"
  local line="" line_no=0 port="" value=""
  [ -f "$file" ] || return 0
  csv_require_header "$file" "$header" || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line"; then
      _tls_render_validation_error "$file" "$line_no" "$CSV_PARSE_ERROR"
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne 2 ]; then
      _tls_render_validation_error "$file" "$line_no" "expected 2 columns, got ${CSV_FIELD_COUNT}"
      return 1
    fi
    port="${CSV_FIELDS[0]}"
    value="${CSV_FIELDS[1]}"
    if ! is_valid_port "$port"; then
      _tls_render_validation_error "$file" "$line_no" "port '${port}' is invalid"
      return 1
    fi
    case "$kind" in
    protocols)
      _validate_tls_protocol_string_for_render "$value" "$file" "$line_no" || return 1
      ;;
    ciphers)
      _validate_tls_cipher_string_for_render "$value" "$file" "$line_no" || return 1
      ;;
    *)
      _tls_render_validation_error "$file" "$line_no" "unknown TLS override kind '${kind}'"
      return 1
      ;;
    esac
  done <"$file"
  return 0
}


function validate_tls_settings_for_render() {
  _validate_tls_protocol_string_for_render "${TLS_PROTOCOLS:-}" "TLS_PROTOCOLS" 0 || return 1
  _validate_tls_cipher_string_for_render "${TLS_CIPHERS:-}" "TLS_CIPHERS" 0 || return 1
  _validate_port_tls_file_for_render "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" protocols || return 1
  _validate_port_tls_file_for_render "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" ciphers || return 1
  return 0
}


function _require_https_port_mapping() {
  local port="$1"

  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Error] No port mappings configured; cannot set TLS overrides for port $port." >&2
    return 1
  fi

  local proto="" domain="" found="false"
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] &&
      [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ]; then
      domain="${STATE_BP_DOMAIN:-}"
      proto="${STATE_BP_PROTOCOL:-}"
      found="true"
      break
    fi
  done <"$BACKEND_PORTS_FILE"

  if [ "$found" != "true" ]; then
    echo "[Error] Port $port is not mapped; add an HTTPS port mapping before setting TLS overrides." >&2
    return 1
  fi

  if [ "$proto" != "https" ]; then
    echo "[Error] Port $port for domain $domain uses protocol '$proto'; TLS overrides require HTTPS." >&2
    return 1
  fi

  return 0
}


function get_port_tls_ciphers() {
  local port="${1:-}"
  local val="$TLS_CIPHERS"
  if [ -n "$port" ] && [ -f "$PORT_TLS_CIPHERS_FILE" ]; then
    local custom=""
    custom="$(state_csv_get_two_col_value "$PORT_TLS_CIPHERS_FILE" "$STATE_PORT_TLS_CIPHERS_HEADER" "$port" "" 2>/dev/null || true)"
    [ -n "$custom" ] && val="$custom"
  fi
  echo "$val"
}


function get_port_tls_protocols() {
  local port="${1:-}"
  local val="$TLS_PROTOCOLS"
  if [ -n "$port" ] && [ -f "$PORT_TLS_PROTOCOLS_FILE" ]; then
    local custom=""
    custom="$(state_csv_get_two_col_value "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" "$port" "" 2>/dev/null || true)"
    [ -n "$custom" ] && val="$custom"
  fi
  echo "$val"
}
