# shellcheck shell=bash
# CAPTURE_SCOPE is a helper output consumed by start_capture.
# shellcheck disable=SC2034

function _capture_normalize_scope() {
  local raw="${1:-}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
  all) CAPTURE_SCOPE="all" ;;
  backends | backend) CAPTURE_SCOPE="backends" ;;
  clients | client) CAPTURE_SCOPE="clients" ;;
  clients-backends | clients_backends | clientsandbackends | clients-and-backends | client-backend | client_backends)
    CAPTURE_SCOPE="clients-backends"
    ;;
  *)
    echo "[Error] Invalid capture scope: '${1:-}'. Use all, backends, clients, or clients-backends." >&2
    return 1
    ;;
  esac
}

# A blank submitted line is a selection; EOF (even with a partial line) is
# cancellation. The general reader intentionally accepts EOF as an empty value.
function _capture_read_selection() {
  local prompt="${1:-}" output_var="${2:-}" capture_answer="" read_status=0
  require_valid_var_name "$output_var" || return 1
  if [ -t 0 ] && [ -t 1 ]; then
    read -r -e -p "$prompt" capture_answer || read_status=$?
  else
    read -r -p "$prompt" capture_answer || read_status=$?
  fi
  if [ "$read_status" -ne 0 ]; then
    echo "[Info] Packet capture cancelled: input ended before the selection was submitted." >&2
    return "$read_status"
  fi
  printf -v "$output_var" '%s' "$capture_answer"
}

function _capture_split_targets() {
  local input="${1:-}"
  # read -a performs field splitting without pathname expansion. Replace line
  # separators first because read consumes only one line, even with custom IFS.
  input="${input//,/ }"
  input="${input//$'\n'/ }"
  local IFS=$' \t\r'
  CAPTURE_TOKENS=()
  read -r -a CAPTURE_TOKENS <<<"$input"
}

function _capture_unique_values() {
  CAPTURE_UNIQUE=()
  local value="" existing="" seen=false
  for value in "$@"; do
    seen=false
    if [ ${#CAPTURE_UNIQUE[@]} -gt 0 ]; then
      for existing in "${CAPTURE_UNIQUE[@]}"; do
        if [ "$existing" = "$value" ]; then
          seen=true
          break
        fi
      done
    fi
    [ "$seen" = true ] || CAPTURE_UNIQUE+=("$value")
  done
}

function _capture_normalize_port() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]{1,5}$ ]] || return 1
  CAPTURE_PORT=$((10#$value))
  [ "$CAPTURE_PORT" -ge 1 ] && [ "$CAPTURE_PORT" -le 65535 ]
}

function _capture_normalize_ipv4() {
  local value="${1:-}"
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS='.' a="" b="" c="" d="" octet=""
  read -r a b c d <<<"$value"
  CAPTURE_IPV4=""
  for octet in "$a" "$b" "$c" "$d"; do
    octet=$((10#$octet))
    [ "$octet" -le 255 ] || return 1
    CAPTURE_IPV4="${CAPTURE_IPV4:+${CAPTURE_IPV4}.}${octet}"
  done
}

function _capture_read_backend_rows() {
  CAPTURE_BACKEND_ROWS=()
  CAPTURE_AVAILABLE_BACKENDS=()
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Error] No configured backends are available for the requested capture scope." >&2
    return 1
  fi
  _csv_runtime_state_guard_if_declared "$BACKEND_PORTS_FILE" "CSV file" || return 1
  local line="" line_no=0 domain=""
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then
      if [ "${line%$'\r'}" != "$STATE_BACKEND_PORTS_HEADER" ]; then
        echo "[Error] Invalid backend state header; refusing a partial capture filter." >&2
        return 1
      fi
      continue
    fi
    if ! state_backend_ports_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_PORTS_COLS" ]; then
      echo "[Error] Invalid backend state at line ${line_no}; refusing a partial capture filter." >&2
      return 1
    fi
    case "${STATE_BP_RECORD_TYPE:-}" in
    backend | port | path) ;;
    *)
      echo "[Error] Unknown backend state record type at line ${line_no}; refusing a partial capture filter." >&2
      return 1
      ;;
    esac
    domain="$(normalize_domain "${STATE_BP_DOMAIN:-}")"
    if ! is_valid_domain "$domain"; then
      echo "[Error] Invalid configured backend domain for packet capture: '${domain}'." >&2
      return 1
    fi
    CAPTURE_BACKEND_ROWS+=("$line")
    if [ "${STATE_BP_RECORD_TYPE:-}" = backend ]; then
      CAPTURE_AVAILABLE_BACKENDS+=("$domain")
    fi
  done <"$BACKEND_PORTS_FILE" || return 1
  if [ ${#CAPTURE_AVAILABLE_BACKENDS[@]} -eq 0 ]; then
    echo "[Error] No configured backends are available for the requested capture scope." >&2
    return 1
  fi
  _capture_unique_values "${CAPTURE_AVAILABLE_BACKENDS[@]}"
  CAPTURE_AVAILABLE_BACKENDS=("${CAPTURE_UNIQUE[@]}")
}

function _capture_resolve_backend_filters() {
  CAPTURE_BACKEND_PORTS=()
  CAPTURE_BACKEND_IPS=()
  local target="" row="" domain="" found=false port="" value="" network_row="" ip=""
  for target in "$@"; do
    found=false
    for row in "${CAPTURE_BACKEND_ROWS[@]}"; do
      state_backend_ports_parse_line "$row" || return 1
      domain="$(normalize_domain "${STATE_BP_DOMAIN:-}")"
      [ "$target" = "$domain" ] || continue
      case "${STATE_BP_RECORD_TYPE:-}" in
      backend)
        found=true
        value="${STATE_BP_BACKEND_UPSTREAM:-}"
        port="${value##*:}"
        if [[ "$value" != *:* ]] || ! _capture_normalize_port "$port"; then
          echo "[Error] Invalid upstream port for capture backend '${target}'." >&2
          return 1
        fi
        CAPTURE_BACKEND_PORTS+=("$CAPTURE_PORT")
        ;;
      port)
        for port in "${STATE_BP_LISTEN_PORT:-}" "${STATE_BP_UPSTREAM_PORT:-}"; do
          if ! _capture_normalize_port "$port"; then
            echo "[Error] Invalid mapped port for capture backend '${target}'." >&2
            return 1
          fi
          CAPTURE_BACKEND_PORTS+=("$CAPTURE_PORT")
        done
        ;;
      esac
    done
    if [ "$found" != true ]; then
      echo "[Error] Unknown capture backend: '${target}'. Every requested backend must be configured." >&2
      return 1
    fi
    _backend_container_snapshot "$target" || return 1
    if [ "$BACKEND_CONTAINER_STATUS" = running ]; then
      while IFS= read -r network_row || [ -n "$network_row" ]; do
        ip="${network_row#*|}"
        [ -n "$ip" ] || continue
        if ! _capture_normalize_ipv4 "$ip"; then
          echo "[Error] Invalid container IPv4 address for capture backend '${target}'." >&2
          return 1
        fi
        CAPTURE_BACKEND_IPS+=("$CAPTURE_IPV4")
      done <<<"$BACKEND_CONTAINER_NETWORKS"
    fi
  done
}

# Output arrays are initialized for every request and consumed only on success.
# An intentionally unrestricted capture is the only successful empty BPF.
function _capture_build_filter() {
  local scope="${1:-}" backend_input="${2:-}" client_input="${3:-}"
  CAPTURE_FILTER_ARGS=()
  CAPTURE_BACKEND_TARGETS=()
  CAPTURE_CLIENT_HOSTS=()
  local -a backend_filter=() client_filter=()
  local token="" i=0

  case "$scope" in
  all)
    if [ -n "$backend_input" ] || [ -n "$client_input" ]; then
      echo "[Error] Capture scope all cannot be combined with backend or client restrictions." >&2
      return 1
    fi
    return 0
    ;;
  backends)
    if [ -n "$client_input" ]; then
      echo "[Error] Client restrictions require capture scope clients or clients-backends." >&2
      return 1
    fi
    ;;
  clients)
    if [ -n "$backend_input" ]; then
      echo "[Error] Backend restrictions require capture scope backends or clients-backends." >&2
      return 1
    fi
    ;;
  clients-backends) ;;
  *)
    echo "[Error] Invalid capture scope: '${scope}'." >&2
    return 1
    ;;
  esac

  if [ "$scope" = clients ] || [ "$scope" = clients-backends ]; then
    _capture_split_targets "$client_input"
    if [ ${#CAPTURE_TOKENS[@]} -eq 0 ]; then
      echo "[Error] The requested capture scope requires at least one client IPv4 address." >&2
      return 1
    fi
    for token in "${CAPTURE_TOKENS[@]}"; do
      if ! _capture_normalize_ipv4 "$token"; then
        echo "[Error] Invalid client IP filter token: '$token'. Use IPv4 addresses only." >&2
        return 1
      fi
      CAPTURE_CLIENT_HOSTS+=("$CAPTURE_IPV4")
    done
    _capture_unique_values "${CAPTURE_CLIENT_HOSTS[@]}"
    CAPTURE_CLIENT_HOSTS=("${CAPTURE_UNIQUE[@]}")
    client_filter=("(" "host" "${CAPTURE_CLIENT_HOSTS[0]}")
    for ((i = 1; i < ${#CAPTURE_CLIENT_HOSTS[@]}; i++)); do
      client_filter+=("or" "host" "${CAPTURE_CLIENT_HOSTS[$i]}")
    done
    client_filter+=(")")
  fi

  if [ "$scope" = backends ] || [ "$scope" = clients-backends ]; then
    _capture_read_backend_rows || return 1
    _capture_split_targets "$backend_input"
    if [ ${#CAPTURE_TOKENS[@]} -eq 0 ]; then
      CAPTURE_BACKEND_TARGETS=("${CAPTURE_AVAILABLE_BACKENDS[@]}")
    else
      for token in "${CAPTURE_TOKENS[@]}"; do
        token="$(normalize_domain "$token")"
        if ! is_valid_domain "$token"; then
          echo "[Error] Invalid capture backend domain: '${token}'." >&2
          return 1
        fi
        CAPTURE_BACKEND_TARGETS+=("$token")
      done
      _capture_unique_values "${CAPTURE_BACKEND_TARGETS[@]}"
      CAPTURE_BACKEND_TARGETS=("${CAPTURE_UNIQUE[@]}")
    fi
    _capture_resolve_backend_filters "${CAPTURE_BACKEND_TARGETS[@]}" || return 1
    if [ ${#CAPTURE_BACKEND_PORTS[@]} -eq 0 ] && [ ${#CAPTURE_BACKEND_IPS[@]} -eq 0 ]; then
      echo "[Error] The requested backends did not resolve to a capture filter." >&2
      return 1
    fi
    backend_filter=("(")
    if [ ${#CAPTURE_BACKEND_PORTS[@]} -gt 0 ]; then
      _capture_unique_values "${CAPTURE_BACKEND_PORTS[@]}"
      backend_filter+=("(" "port" "${CAPTURE_UNIQUE[0]}")
      for ((i = 1; i < ${#CAPTURE_UNIQUE[@]}; i++)); do
        backend_filter+=("or" "port" "${CAPTURE_UNIQUE[$i]}")
      done
      backend_filter+=(")")
    fi
    if [ ${#CAPTURE_BACKEND_IPS[@]} -gt 0 ]; then
      [ ${#backend_filter[@]} -eq 1 ] || backend_filter+=("or")
      _capture_unique_values "${CAPTURE_BACKEND_IPS[@]}"
      backend_filter+=("(" "host" "${CAPTURE_UNIQUE[0]}")
      for ((i = 1; i < ${#CAPTURE_UNIQUE[@]}; i++)); do
        backend_filter+=("or" "host" "${CAPTURE_UNIQUE[$i]}")
      done
      backend_filter+=(")")
    fi
    backend_filter+=(")")
  fi

  case "$scope" in
  clients) CAPTURE_FILTER_ARGS=("${client_filter[@]}") ;;
  backends) CAPTURE_FILTER_ARGS=("${backend_filter[@]}") ;;
  clients-backends)
    # Keep the backend OR expression together: no backend address may bypass
    # the client restriction, regardless of libpcap operator precedence.
    CAPTURE_FILTER_ARGS=("(" "${client_filter[@]}" "and" "${backend_filter[@]}" ")")
    ;;
  esac
  if [ ${#CAPTURE_FILTER_ARGS[@]} -eq 0 ]; then
    echo "[Error] Refusing an empty filter for restricted capture scope '${scope}'." >&2
    return 1
  fi
}
