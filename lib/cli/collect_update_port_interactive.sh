# shellcheck shell=bash

COLLECT_UPDATE_PORT_CUR_DOMAIN=""
COLLECT_UPDATE_PORT_CUR_NGINX=""
COLLECT_UPDATE_PORT_CUR_UPSTREAM=""
COLLECT_UPDATE_PORT_CUR_PROTO=""
COLLECT_UPDATE_PORT_CUR_CERT=""
COLLECT_UPDATE_PORT_CUR_WS=""
COLLECT_UPDATE_PORT_CUR_HTTP3=""
COLLECT_UPDATE_PORT_CUR_ALT_SVC=""

function _collect_update_port_choose_from_lines() {
  local __out_var="${1:-}" prompt="${2:-}" opts="${3:-}" default="${4:-}" manual_prompt="${5:-}"
  local line="" choice_value="" choice_label="" idx="" val=""
  local _vals=() _disp=()

  require_valid_var_name "$__out_var" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    choice_value=""
    choice_label=""
    cli_choice_line_to_value_label "$line" choice_value choice_label
    _vals+=("$choice_value")
    _disp+=("$choice_label")
  done <<<"$opts"
  _vals+=("__BACK__")
  _disp+=("Back")

  if ! choose_option idx "$prompt:" "${_disp[@]}"; then
    return 2
  fi
  if [ -z "${idx:-}" ] || ! [ "$idx" -ge 0 ] 2>/dev/null || [ "$idx" -ge ${#_vals[@]} ] 2>/dev/null; then
    return 2
  fi

  val="${_vals[$idx]}"
  case "$val" in
  __BACK__)
    return 2
    ;;
  __DEFAULT__)
    val="$default"
    ;;
  __MANUAL__)
    [ -n "$manual_prompt" ] || manual_prompt="$prompt"
    read_with_editing "${manual_prompt}: " val "$default"
    if is_back_input "$val"; then
      return 2
    fi
    [ -n "$val" ] || val="$default"
    ;;
  esac

  printf -v "$__out_var" '%s' "$val"
  return 0
}

function _collect_update_port_load_current_mapping() {
  local domain="${1:-}" listen_port="${2:-}" line="" line_no=0 normalized_cur_cert=""

  COLLECT_UPDATE_PORT_CUR_DOMAIN=""
  COLLECT_UPDATE_PORT_CUR_NGINX=""
  COLLECT_UPDATE_PORT_CUR_UPSTREAM=""
  COLLECT_UPDATE_PORT_CUR_PROTO=""
  COLLECT_UPDATE_PORT_CUR_CERT=""
  COLLECT_UPDATE_PORT_CUR_WS=""
  COLLECT_UPDATE_PORT_CUR_HTTP3=""
  COLLECT_UPDATE_PORT_CUR_ALT_SVC=""

  [ -n "$domain" ] || return 1
  [ -n "$listen_port" ] || return 1
  [ -f "$BACKEND_PORTS_FILE" ] || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] || continue
    [ "${STATE_BP_DOMAIN:-}" = "$domain" ] || continue
    [ "${STATE_BP_LISTEN_PORT:-}" = "$listen_port" ] || continue

    COLLECT_UPDATE_PORT_CUR_DOMAIN="$STATE_BP_DOMAIN"
    COLLECT_UPDATE_PORT_CUR_NGINX="$STATE_BP_LISTEN_PORT"
    COLLECT_UPDATE_PORT_CUR_UPSTREAM="$STATE_BP_UPSTREAM_PORT"
    COLLECT_UPDATE_PORT_CUR_PROTO="$STATE_BP_PROTOCOL"
    COLLECT_UPDATE_PORT_CUR_CERT="$STATE_BP_CERT_REF"
    COLLECT_UPDATE_PORT_CUR_WS="$STATE_BP_WS"
    COLLECT_UPDATE_PORT_CUR_HTTP3="${STATE_BP_HTTP3:-off}"
    COLLECT_UPDATE_PORT_CUR_ALT_SVC="${STATE_BP_ALT_SVC:-auto}"
    if [ -n "$COLLECT_UPDATE_PORT_CUR_CERT" ] && [ "$COLLECT_UPDATE_PORT_CUR_CERT" != "none" ]; then
      relativize_cert_dir normalized_cur_cert "$COLLECT_UPDATE_PORT_CUR_CERT" || normalized_cur_cert="$COLLECT_UPDATE_PORT_CUR_CERT"
      COLLECT_UPDATE_PORT_CUR_CERT="$normalized_cur_cert"
    fi
    return 0
  done <"$BACKEND_PORTS_FILE"

  return 1
}

function collect_update_port_interactive() {
  local domain="" current_port="" nginx_port="" upstream_port="" protocol="" cert_dir="" ws="" http3_opt="" alt_svc_opt=""
  local step=0 opts="" status=0

  while true; do
    case "$step" in
    0)
      CURRENT_ARGS=()
      opts="$(get_arg_choices "update-port" "domain")"
      if [ -z "$opts" ]; then
        echo "[Info] No backends configured." >&2
        return 1
      fi
      _collect_update_port_choose_from_lines domain "Domain" "$opts" "" ""
      status=$?
      case "$status" in
      0) step=1 ;;
      2) return 1 ;;
      *) return "$status" ;;
      esac
      ;;
    1)
      CURRENT_ARGS=("$domain")
      opts="$(get_arg_choices "update-port" "nginx_port")"
      if [ -z "$opts" ]; then
        echo "[Info] No port mappings configured for ${domain}." >&2
        step=0
        continue
      fi
      _collect_update_port_choose_from_lines current_port "Port mapping to update" "$opts" "" ""
      status=$?
      case "$status" in
      0) ;;
      2)
        step=0
        continue
        ;;
      *) return "$status" ;;
      esac
      if ! _collect_update_port_load_current_mapping "$domain" "$current_port"; then
        echo "[Error] Failed to load selected port mapping for ${domain}:${current_port}." >&2
        step=1
        continue
      fi
      nginx_port="$COLLECT_UPDATE_PORT_CUR_NGINX"
      upstream_port="$COLLECT_UPDATE_PORT_CUR_UPSTREAM"
      protocol="$COLLECT_UPDATE_PORT_CUR_PROTO"
      cert_dir="${COLLECT_UPDATE_PORT_CUR_CERT:-none}"
      ws="$COLLECT_UPDATE_PORT_CUR_WS"
      http3_opt="$COLLECT_UPDATE_PORT_CUR_HTTP3"
      alt_svc_opt="$COLLECT_UPDATE_PORT_CUR_ALT_SVC"
      step=2
      ;;
    2)
      opts="__DEFAULT__|Keep current: ${COLLECT_UPDATE_PORT_CUR_NGINX}"$'\n'"$(__arg_choices_common_listen_ports)"
      _collect_update_port_choose_from_lines nginx_port "New listen port" "$opts" "$COLLECT_UPDATE_PORT_CUR_NGINX" "New listen port"
      status=$?
      case "$status" in
      0)
        if ! is_valid_port "$nginx_port"; then
          echo "[Error] Invalid listen port." >&2
          continue
        fi
        step=3
        ;;
      2) step=1 ;;
      *) return "$status" ;;
      esac
      ;;
    3)
      CURRENT_ARGS=("$domain" "$current_port" "$COLLECT_UPDATE_PORT_CUR_UPSTREAM")
      opts="$(get_arg_choices "update-port" "container_port")"
      _collect_update_port_choose_from_lines upstream_port "Backend container port" "$opts" "$COLLECT_UPDATE_PORT_CUR_UPSTREAM" "Backend container port"
      status=$?
      case "$status" in
      0)
        if ! is_valid_port "$upstream_port"; then
          echo "[Error] Invalid container port." >&2
          continue
        fi
        step=4
        ;;
      2) step=2 ;;
      *) return "$status" ;;
      esac
      ;;
    4)
      CURRENT_ARGS=("$domain" "$current_port" "$COLLECT_UPDATE_PORT_CUR_UPSTREAM" "$COLLECT_UPDATE_PORT_CUR_PROTO")
      opts="$(get_arg_choices "update-port" "protocol")"
      _collect_update_port_choose_from_lines protocol "Protocol" "$opts" "$COLLECT_UPDATE_PORT_CUR_PROTO" ""
      status=$?
      case "$status" in
      0)
        if ! is_valid_protocol "$protocol"; then
          echo "[Error] Invalid protocol." >&2
          continue
        fi
        step=5
        ;;
      2) step=3 ;;
      *) return "$status" ;;
      esac
      ;;
    5)
      if [ "$protocol" != "https" ]; then
        cert_dir=""
        http3_opt="off"
        alt_svc_opt="auto"
        step=8
        continue
      fi
      CURRENT_ARGS=("$domain" "$current_port" "$upstream_port" "$protocol")
      opts="__DEFAULT__|Keep current: ${COLLECT_UPDATE_PORT_CUR_CERT:-none}"$'\n'"$(get_arg_choices "update-port" "cert_path")"$'\n'"__MANUAL__|Enter manually..."
      _collect_update_port_choose_from_lines cert_dir "Certificate" "$opts" "${COLLECT_UPDATE_PORT_CUR_CERT:-none}" "Certificate path"
      status=$?
      case "$status" in
      0)
        [ -n "$cert_dir" ] || cert_dir="none"
        step=6
        ;;
      2) step=4 ;;
      *) return "$status" ;;
      esac
      ;;
    6)
      opts="__DEFAULT__|Keep current: ${COLLECT_UPDATE_PORT_CUR_HTTP3:-off}"$'\n'"$(get_arg_choices "update-port" "http3")"
      _collect_update_port_choose_from_lines http3_opt "HTTP/3" "$opts" "${COLLECT_UPDATE_PORT_CUR_HTTP3:-off}" ""
      status=$?
      case "$status" in
      0)
        if ! is_valid_http3_flag "$http3_opt"; then
          echo "[Error] Invalid HTTP/3 flag." >&2
          continue
        fi
        step=7
        ;;
      2) step=5 ;;
      *) return "$status" ;;
      esac
      ;;
    7)
      opts="__DEFAULT__|Keep current: ${COLLECT_UPDATE_PORT_CUR_ALT_SVC:-auto}"$'\n'"$(get_arg_choices "update-port" "alt_svc")"
      _collect_update_port_choose_from_lines alt_svc_opt "Alt-Svc" "$opts" "${COLLECT_UPDATE_PORT_CUR_ALT_SVC:-auto}" "Alt-Svc"
      status=$?
      case "$status" in
      0)
        if ! is_valid_alt_svc_mode "$alt_svc_opt"; then
          echo "[Error] Invalid Alt-Svc value." >&2
          continue
        fi
        step=8
        ;;
      2) step=6 ;;
      *) return "$status" ;;
      esac
      ;;
    8)
      if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
        ws="no"
        step=9
        continue
      fi
      opts="__DEFAULT__|Keep current: ${COLLECT_UPDATE_PORT_CUR_WS:-no}"$'\n'"yes|Yes"$'\n'"no|No"
      _collect_update_port_choose_from_lines ws "WebSocket" "$opts" "${COLLECT_UPDATE_PORT_CUR_WS:-no}" ""
      status=$?
      case "$status" in
      0)
        if ! is_yes_no "$ws"; then
          echo "[Error] Invalid WebSocket value." >&2
          continue
        fi
        step=9
        ;;
      2)
        if [ "$protocol" = "https" ]; then
          step=7
        else
          step=4
        fi
        ;;
      *) return "$status" ;;
      esac
      ;;
    9)
      break
      ;;
    esac
  done

  SELECTED_CMD="update-port"
  SELECTED_ARGS=("$domain" "$current_port" --nginx-port "$nginx_port" --container-port "$upstream_port" --protocol "$protocol")
  case "$protocol" in
  https)
    SELECTED_ARGS+=(--cert "${cert_dir:-none}" --ws "$ws" --http3 "$http3_opt" --alt-svc "$alt_svc_opt")
    ;;
  http)
    SELECTED_ARGS+=(--ws "$ws")
    ;;
  esac
  PROMPT_ARGS_COLLECTED=("${SELECTED_ARGS[@]}")
  return 0
}
