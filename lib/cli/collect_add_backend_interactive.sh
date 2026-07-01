# shellcheck shell=bash

function _collect_add_backend_choose_from_lines() {
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

# Guided interactive flow for add-backend with backtracking and sensible ordering
function collect_add_backend_interactive() {
  local domain="" protocol="http" network_name="$DEFAULT_NETWORK" image="" container_port="" listen="" cert_path="" ws="no" expose_now="yes" docker_opts=""
  local redirect_pref="yes" redirect_target=""
  local step=0

  while true; do
    case "$step" in
    0) # domain
      while true; do
        local _dom_choice
        if ! choose_option _dom_choice "Domain:" "Enter domain" "Back"; then
          return 1
        fi
        if [ "$_dom_choice" -eq 1 ]; then
          return 1
        fi
        read_with_editing "Domain: " domain
        if is_back_input "$domain"; then
          return 1
        fi
        if [ -z "$domain" ]; then
          echo "[Error] Domain is required. Choose Back, press Esc/Q, or type back to return to the menu." >&2
          continue
        fi
        step=1
        break
      done
      ;;
    1) # protocol first
      local _vals=(http https tcp udp __BACK__) _disp=("HTTP" "HTTPS" "TCP" "UDP" "Back") idx
      if ! choose_option idx "Protocol:" "${_disp[@]}"; then
        return 1
      fi
      protocol="${_vals[$idx]}"
      if [ "$protocol" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      step=2
      ;;
    2) # network near top
      CURRENT_ARGS=("$domain")
      local opts idx line _vals=() _disp=() manual_seen=0
      opts="$(get_arg_choices "add-backend" "network")"
      if [ -n "$opts" ]; then
        while IFS= read -r line; do
          if [[ "$line" == *"|"* ]]; then
            local _nv="${line%%|*}" _nd="${line#*|}"
            _vals+=("$_nv")
            _disp+=("$_nd")
            [ "$_nv" = "__MANUAL__" ] && manual_seen=1
          else
            _vals+=("$line")
            _disp+=("$line")
            [ "$line" = "__MANUAL__" ] && manual_seen=1
          fi
        done <<<"$opts"
      fi
      if ((!manual_seen)); then
        _vals+=("__MANUAL__")
        _disp+=("Enter manually...")
      fi
      _vals+=("__BACK__")
      _disp+=("Back")
      if ! choose_option idx "Network:" "${_disp[@]}"; then
        return 1
      fi
      network_name="${_vals[$idx]}"
      if [ "$network_name" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      if [ "$network_name" = "__MANUAL__" ]; then
        read_with_editing "Network name [$DEFAULT_NETWORK]: " network_name "$DEFAULT_NETWORK"
        if is_back_input "$network_name"; then
          step=$((step - 1))
          continue
        fi
        [ -n "$network_name" ] || network_name="$DEFAULT_NETWORK"
      fi
      step=3
      ;;
    3) # image
      CURRENT_ARGS=("$domain")
      local img_opts idx_img img_line _vals_img=() _disp_img=()
      img_opts="$(get_arg_choices "add-backend" "image")"
      if [ -n "$img_opts" ]; then
        while IFS= read -r img_line; do
          if [[ "$img_line" == *"|"* ]]; then
            _vals_img+=("${img_line%%|*}")
            _disp_img+=("${img_line#*|}")
            if [ "${img_line%%|*}" = "__MANUAL__" ]; then
              _manual_seen=1
            fi
          else
            _vals_img+=("$img_line")
            _disp_img+=("$img_line")
          fi
        done <<<"$img_opts"
      fi
      # Add manual option only if not already present
      if ! printf '%s\n' "${_vals_img[@]}" | grep -qx "__MANUAL__"; then
        _vals_img+=("__MANUAL__")
        _disp_img+=("Enter manually...")
      fi
      _vals_img+=("__BACK__")
      _disp_img+=("Back")
      if ! choose_option idx_img "Docker image:" "${_disp_img[@]}"; then
        return 1
      fi
      image="${_vals_img[$idx_img]}"
      if [ "$image" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      if [ "$image" = "__MANUAL__" ]; then
        read_with_editing "Docker image: " image
        if is_back_input "$image"; then
          step=$((step - 1))
          continue
        fi
      fi
      [ -n "$image" ] || continue
      step=4
      ;;
    4) # container port
      CURRENT_ARGS=("$domain" "$image")
      local cp_prompt="Container port"
      local default_cp=""
      local cp_opts cp_line idx_cp cp_has_manual=0 _cp_vals=() _cp_disp=()
      cp_opts="$(get_arg_choices "add-backend" "container_port")"
      if [ -n "$cp_opts" ]; then
        while IFS= read -r cp_line; do
          if [[ "$cp_line" == *"|"* ]]; then
            local _cp_val="${cp_line%%|*}" _cp_label="${cp_line#*|}"
            _cp_vals+=("$_cp_val")
            _cp_disp+=("$_cp_label")
            [ "$_cp_val" = "__MANUAL__" ] && cp_has_manual=1
          else
            _cp_vals+=("$cp_line")
            _cp_disp+=("$cp_line")
          fi
        done <<<"$cp_opts"
        if ((!cp_has_manual)); then
          _cp_vals+=("__MANUAL__")
          _cp_disp+=("Enter manually...")
        fi
        _cp_vals+=("__BACK__")
        _cp_disp+=("Back")
        if ! choose_option idx_cp "$cp_prompt:" "${_cp_disp[@]}"; then
          return 1
        fi
        container_port="${_cp_vals[$idx_cp]}"
        if [ "$container_port" = "__BACK__" ]; then
          step=$((step - 1))
          continue
        fi
        if [ "$container_port" = "__MANUAL__" ]; then
          read_with_editing "$cp_prompt: " container_port
          if is_back_input "$container_port"; then
            step=$((step - 1))
            continue
          fi
        fi
      else
        read_with_editing "$cp_prompt: " container_port
        if is_back_input "$container_port"; then
          step=$((step - 1))
          continue
        fi
      fi
      if [ -z "$container_port" ] || ! is_valid_port "$container_port"; then
        echo "[Error] Please enter a valid container port." >&2
        continue
      fi
      step=5
      ;;
    5) # listen port, defaults by protocol
      case "$protocol" in
      http) [ -n "$listen" ] || listen=80 ;;
      https) [ -n "$listen" ] || listen=443 ;;
      tcp | udp) [ -n "$listen" ] || listen="$container_port" ;;
      esac
      local listen_opts="__DEFAULT__|Use default: ${listen}"
      if { [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; } && [ -n "$container_port" ]; then
        listen_opts+=$'\n'"${container_port}|${container_port} (container port)"
      fi
      listen_opts+=$'\n'"$(__arg_choices_common_listen_ports)"
      _collect_add_backend_choose_from_lines listen "Listen port" "$listen_opts" "$listen" "Listen port"
      case $? in
      0) ;;
      2)
        step=$((step - 1))
        continue
        ;;
      *) return 1 ;;
      esac
      if ! is_valid_port "$listen"; then
        echo "[Error] Invalid listen port." >&2
        continue
      fi
      local host_transport="tcp"
      [ "$protocol" = "udp" ] && host_transport="udp"
      if ! assert_host_port_available_or_fail "$listen" "$host_transport"; then
        continue
      fi
      step=6
      ;;
    6) # cert (only https)
      if [ "$protocol" != "https" ]; then
        cert_path=""
        step=7
        continue
      fi
      CURRENT_ARGS=("$domain" "$image" "$container_port" "$protocol" "$listen")
      local c_opts c_line idx_c _c_vals=() _c_disp=()
      c_opts="$(get_arg_choices "add-backend" "cert_path")"
      if [ -n "$c_opts" ]; then
        while IFS= read -r c_line; do
          if [[ "$c_line" == *"|"* ]]; then
            _c_vals+=("${c_line%%|*}")
            _c_disp+=("${c_line#*|}")
          else
            _c_vals+=("$c_line")
            _c_disp+=("$c_line")
          fi
        done <<<"$c_opts"
      fi
      _c_vals+=("__MANUAL__" "__BACK__")
      _c_disp+=("Enter manually..." "Back")
      if ! choose_option idx_c "Certificate path (or generate):" "${_c_disp[@]}"; then
        return 1
      fi
      cert_path="${_c_vals[$idx_c]}"
      if [ "$cert_path" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      if [ "$cert_path" = "__MANUAL__" ]; then
        read_with_editing "Cert directory under certs/ or absolute (or 'selfsigned'/'letsencrypt'): " cert_path
        if is_back_input "$cert_path"; then
          step=$((step - 1))
          continue
        fi
      fi
      step=7
      ;;
    7) # redirect prompt for https
      if [ "$protocol" != "https" ]; then
        redirect_pref=""
        redirect_target=""
        step=9
        continue
      fi
      local r_vals=(yes no __BACK__) r_disp=("Enable redirect" "Do not redirect" "Back") idx_r
      if ! choose_option idx_r "HTTP->HTTPS redirect:" "${r_disp[@]}"; then
        return 1
      fi
      redirect_pref="${r_vals[$idx_r]}"
      if [ "$redirect_pref" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      [ "$redirect_pref" = "no" ] && redirect_target=""
      step=8
      ;;
    8) # redirect target
      if [ "$protocol" != "https" ] || [ "$redirect_pref" = "no" ]; then
        redirect_target=""
        step=9
        continue
      fi
      [ -n "$redirect_target" ] || redirect_target="$listen"
      local redirect_opts="__DEFAULT__|Use HTTPS listen port: ${listen}"$'\n'"443|443"$'\n'"8443|8443"$'\n'"__MANUAL__|Enter manually..."
      _collect_add_backend_choose_from_lines redirect_target "Redirect target port" "$redirect_opts" "$listen" "Redirect target port"
      case $? in
      0) ;;
      2)
        step=$((step - 1))
        continue
        ;;
      *) return 1 ;;
      esac
      if ! is_valid_port "$redirect_target"; then
        echo "[Error] Invalid redirect port." >&2
        continue
      fi
      step=9
      ;;
    9) # ws (skip for tcp/udp)
      if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
        ws="no"
        step=10
        continue
      fi
      local ws_vals=(no yes __BACK__) ws_disp=("Disabled" "Enabled" "Back") idx_ws
      if ! choose_option idx_ws "WebSocket support:" "${ws_disp[@]}"; then
        return 1
      fi
      ws="${ws_vals[$idx_ws]}"
      if [ "$ws" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      step=10
      ;;
    10) # expose
      local ex_vals=(yes no __BACK__) ex_disp=("Expose now" "Do not expose" "Back") idx_ex
      if ! choose_option idx_ex "Expose port now:" "${ex_disp[@]}"; then
        return 1
      fi
      expose_now="${ex_vals[$idx_ex]}"
      if [ "$expose_now" = "__BACK__" ]; then
        step=$((step - 1))
        continue
      fi
      step=11
      ;;
    11) # docker opts last
      read_multiline_with_editing "Additional docker run options (optional; finish with empty line): " docker_opts
      if is_back_input "$docker_opts"; then
        step=$((step - 1))
        continue
      fi
      step=12
      ;;
    esac
    if ((step < 0)); then
      return 1
    fi
    if ((step >= 12)); then
      break
    fi
  done

  [ -n "$redirect_target" ] || redirect_target="$listen"

  SELECTED_CMD="add-backend"
  SELECTED_ARGS=("$domain" "$image" "$container_port" "$protocol" "$listen" "$cert_path" "$ws" "$docker_opts" "$network_name" "$expose_now" "$redirect_pref" "$redirect_target")
  return 0
}
