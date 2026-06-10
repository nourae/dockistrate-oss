# shellcheck shell=bash

function _lsof_udp_local_port_match() {
  local port="${1:-}"
  awk -v suffix=":${port}" '
    NR > 1 {
      name = $NF
      sub(/->.*/, "", name)
      if (name ~ suffix "$") {
        found = 1
        exit
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

function _lsof_udp_owner_line() {
  local port="${1:-}"
  awk -v suffix=":${port}" '
    NR > 1 {
      name = $NF
      sub(/->.*/, "", name)
      if (name ~ suffix "$") {
        print $2 "|" $1
        exit
      }
    }
  '
}

function is_host_port_listening() {
  local port="${1:-}" protocol="${2:-tcp}"
  if ! is_valid_port "$port"; then
    return 1
  fi
  case "$protocol" in
  tcp | udp) ;;
  *)
    return 1
    ;;
  esac

  if command -v lsof >/dev/null 2>&1; then
    if [ "$protocol" = "tcp" ]; then
      if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        return 0
      fi
    else
      if lsof -nP -iUDP:"$port" 2>/dev/null | _lsof_udp_local_port_match "$port"; then
        return 0
      fi
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    if [ "$protocol" = "tcp" ]; then
      if ss -lnt 2>/dev/null | awk -v p=":$port" '
           $1 == "LISTEN" && ($4 ~ (p "$") || $4 ~ (p "[^0-9]")) { found=1; exit }
           END { exit(found ? 0 : 1) }
         '; then
        return 0
      fi
    else
      if ss -lnu 2>/dev/null | awk -v p=":$port" '
           ($4 ~ (p "$") || $4 ~ (p "[^0-9]")) { found=1; exit }
           END { exit(found ? 0 : 1) }
         '; then
        return 0
      fi
    fi
  fi

  if command -v netstat >/dev/null 2>&1; then
    if [ "$protocol" = "tcp" ]; then
      if netstat -an 2>/dev/null | grep -E "[\\.:]${port}([^0-9]|[[:space:]]).*LISTEN" >/dev/null 2>&1; then
        return 0
      fi
    else
      if netstat -anu 2>/dev/null | grep -E "[\\.:]${port}([^0-9]|[[:space:]])" >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi

  return 1
}

function port_listener_owner_info() {
  local port="${1:-}" protocol="${2:-tcp}"
  if ! is_valid_port "$port"; then
    return 1
  fi
  case "$protocol" in
  tcp | udp) ;;
  *)
    return 1
    ;;
  esac

  if command -v lsof >/dev/null 2>&1; then
    local lsof_owner=""
    if [ "$protocol" = "tcp" ]; then
      lsof_owner="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 { print $2 "|" $1; exit }')"
    else
      lsof_owner="$(lsof -nP -iUDP:"$port" 2>/dev/null | _lsof_udp_owner_line "$port")"
    fi
    if [ -n "$lsof_owner" ]; then
      echo "$lsof_owner"
      return 0
    fi
  fi

  if command -v ss >/dev/null 2>&1; then
    local ss_line="" pid="" proc=""
    if [ "$protocol" = "tcp" ]; then
      ss_line="$(ss -lntp 2>/dev/null | awk -v p=":$port" '
        $1 == "LISTEN" && ($4 ~ (p "$") || $4 ~ (p "[^0-9]")) { print; exit }
      ')"
    else
      ss_line="$(ss -lnup 2>/dev/null | awk -v p=":$port" '
        ($4 ~ (p "$") || $4 ~ (p "[^0-9]")) { print; exit }
      ')"
    fi
    if [ -n "$ss_line" ]; then
      pid="$(printf '%s\n' "$ss_line" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -n 1)"
      proc="$(printf '%s\n' "$ss_line" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p' | head -n 1)"
      if [ -n "$pid" ]; then
        if [ -z "$proc" ] && command -v ps >/dev/null 2>&1; then
          proc="$(ps -p "$pid" -o comm= 2>/dev/null | head -n 1 | awk '{$1=$1; print}')"
        fi
        [ -n "$proc" ] || proc="unknown"
        echo "${pid}|${proc}"
        return 0
      fi
    fi
  fi

  return 1
}

function is_port_mapped_in_state() {
  local port="${1:-}"
  local protocol="${2:-tcp}"
  local skip_domain="${3:-}"
  local skip_port="${4:-}"
  if ! is_valid_port "$port"; then
    return 1
  fi
  case "$protocol" in
  tcp | udp) ;;
  *)
    return 1
    ;;
  esac
  [ -f "$BACKEND_PORTS_FILE" ] || return 1

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
    [ "${STATE_BP_LISTEN_PORT:-}" = "$port" ] || continue
    local row_protocol="${STATE_BP_PROTOCOL:-}"
    local row_matches="no"
    case "$protocol" in
    tcp)
      if [ "$row_protocol" = "http" ] || [ "$row_protocol" = "https" ] || [ "$row_protocol" = "tcp" ]; then
        row_matches="yes"
      fi
      ;;
    udp)
      if [ "$row_protocol" = "udp" ] || { [ "$row_protocol" = "https" ] && [ "${STATE_BP_HTTP3:-off}" = "on" ]; }; then
        row_matches="yes"
      fi
      ;;
    esac
    [ "$row_matches" = "yes" ] || continue
    if [ -n "$skip_domain" ] && [ -n "$skip_port" ] &&
      [ "${STATE_BP_DOMAIN:-}" = "$skip_domain" ] &&
      [ "${STATE_BP_LISTEN_PORT:-}" = "$skip_port" ]; then
      continue
    fi
    return 0
  done <"$BACKEND_PORTS_FILE"
  return 1
}

function suggest_free_port() {
  local requested_port="${1:-}"
  local protocol="${2:-tcp}"
  local skip_domain="${3:-}"
  local skip_port="${4:-}"
  if ! is_valid_port "$requested_port"; then
    return 1
  fi

  local start end candidate
  start=$((requested_port + 1))
  end=$((requested_port + 20))
  if [ "$start" -lt 1 ]; then
    start=1
  fi
  if [ "$end" -gt 65535 ]; then
    end=65535
  fi

  candidate="$start"
  while [ "$candidate" -le "$end" ]; do
    if ! is_host_port_listening "$candidate" "$protocol" && ! is_port_mapped_in_state "$candidate" "$protocol" "$skip_domain" "$skip_port"; then
      echo "$candidate"
      return 0
    fi
    candidate=$((candidate + 1))
  done

  for candidate in 9090 8081 8088 8000 8888 8443; do
    if ! is_valid_port "$candidate"; then
      continue
    fi
    if ! is_host_port_listening "$candidate" "$protocol" && ! is_port_mapped_in_state "$candidate" "$protocol" "$skip_domain" "$skip_port"; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

function assert_host_port_available_or_fail() {
  local port="${1:-}"
  local protocol="${2:-tcp}"
  local skip_domain="${3:-}"
  local skip_port="${4:-}"
  local force_check="${5:-false}"
  if ! is_valid_port "$port"; then
    return 1
  fi
  case "$protocol" in
  tcp | udp) ;;
  *)
    return 1
    ;;
  esac

  if [ "$force_check" != "true" ] && [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    return 0
  fi

  if [ "$force_check" != "true" ] && is_port_mapped_in_state "$port" "$protocol" "$skip_domain" "$skip_port"; then
    return 0
  fi

  if ! is_host_port_listening "$port" "$protocol"; then
    return 0
  fi

  local owner_line="" owner_pid="" owner_proc=""
  owner_line="$(port_listener_owner_info "$port" "$protocol" || true)"
  if [ -n "$owner_line" ]; then
    owner_pid="${owner_line%%|*}"
    owner_proc="${owner_line#*|}"
  fi

  if [ -n "$owner_pid" ] && [ -n "$owner_proc" ]; then
    echo "[Error] Host ${protocol} port ${port} is already in use by PID ${owner_pid} (${owner_proc})." >&2
  else
    echo "[Error] Host ${protocol} port ${port} is already in use." >&2
  fi

  local suggested=""
  suggested="$(suggest_free_port "$port" "$protocol" "$skip_domain" "$skip_port" || true)"
  if [ -n "$suggested" ]; then
    echo "[Info] Suggested free port: ${suggested}."
  else
    echo "[Info] Choose a different free port."
  fi

  return 1
}
