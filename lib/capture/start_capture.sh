# shellcheck shell=bash

function _capture_collapse_absolute_path() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  [ -n "$path_in" ] || return 1
  case "$path_in" in
  /*) ;;
  *)
    return 1
    ;;
  esac

  local trimmed="${path_in#/}" old_ifs="$IFS"
  IFS='/'
  local -a parts=()
  read -r -a parts <<<"$trimmed"
  IFS="$old_ifs"

  local -a stack=()
  local segment=""
  if [ ${#parts[@]} -gt 0 ]; then
    for segment in "${parts[@]}"; do
      case "$segment" in
      "" | .) ;;
      ..)
        if [ ${#stack[@]} -gt 0 ]; then
          unset "stack[${#stack[@]}-1]"
        fi
        ;;
      *)
        stack+=("$segment")
        ;;
      esac
    done
  fi

  local collapsed="/"
  if [ ${#stack[@]} -gt 0 ]; then
    collapsed="/${stack[0]}"
    local i=1
    while [ $i -lt ${#stack[@]} ]; do
      collapsed="${collapsed}/${stack[$i]}"
      i=$((i + 1))
    done
  fi

  printf -v "$__var" '%s' "$collapsed"
}

function _capture_resolve_existing_path() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  [ -e "$path_in" ] || return 1

  local resolved=""
  if [ -d "$path_in" ]; then
    resolved="$(cd "$path_in" 2>/dev/null && pwd -P)" || return 1
  else
    local resolved_dir=""
    resolved_dir="$(cd "$(dirname "$path_in")" 2>/dev/null && pwd -P)" || return 1
    resolved="${resolved_dir%/}/$(basename "$path_in")"
  fi

  _capture_collapse_absolute_path resolved "$resolved" || return 1
  printf -v "$__var" '%s' "$resolved"
}

function _capture_resolve_output_path() {
  local __var="$1" path_in="${2:-}"
  require_valid_var_name "$__var" || return 1
  [ -n "$path_in" ] || return 1

  local absolute_path="$path_in"
  if [[ "$absolute_path" != /* ]]; then
    absolute_path="${BASE_DIR%/}/${absolute_path#./}"
  fi

  local search_path="$absolute_path"
  local missing_suffix=""
  while [ ! -e "$search_path" ]; do
    local leaf_name=""
    leaf_name="$(basename "$search_path")"
    if [ -z "$leaf_name" ] || [ "$leaf_name" = "/" ] || [ "$leaf_name" = "." ]; then
      break
    fi

    if [ -n "$missing_suffix" ]; then
      missing_suffix="${leaf_name}/${missing_suffix}"
    else
      missing_suffix="$leaf_name"
    fi

    local parent_path=""
    parent_path="$(dirname "$search_path")"
    if [ "$parent_path" = "$search_path" ]; then
      break
    fi
    search_path="$parent_path"
  done

  local resolved_existing=""
  _capture_resolve_existing_path resolved_existing "$search_path" || return 1

  local resolved_path="$resolved_existing"
  if [ -n "$missing_suffix" ]; then
    resolved_path="${resolved_existing%/}/${missing_suffix}"
  fi

  _capture_collapse_absolute_path resolved_path "$resolved_path" || return 1
  printf -v "$__var" '%s' "$resolved_path"
}

function start_capture() {
  local out_dir="$CAPTURE_DIR" scope="" backend_input="" client_input="" tls_decrypt="false"

  while [ $# -gt 0 ]; do
    case "$1" in
    --scope)
      scope="${2:-$scope}"
      shift 2
      ;;
    --backends)
      backend_input="${2:-}"
      shift 2
      ;;
    --clients)
      client_input="${2:-}"
      shift 2
      ;;
    --folder)
      out_dir="${2:-$out_dir}"
      shift 2
      ;;
    --tls-decrypt)
      tls_decrypt="true"
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      shift
      ;;
    *)
      if [ "$out_dir" = "$CAPTURE_DIR" ]; then
        out_dir="$1"
      fi
      shift
      ;;
    esac
  done

  local capture_image="${CAPTURE_IMAGE:-}"
  if ! is_valid_image_ref "$capture_image"; then
    echo "[Error] Invalid packet capture image reference: ${capture_image}" >&2
    return 1
  fi

  local requested_out_dir="$out_dir"
  if [[ "$out_dir" != /* ]]; then
    local rel="$out_dir"
    rel="${rel#./}"
    rel="${rel%/}"

    # If the relative path already points to the configured capture root
    # (e.g. state/pcaps or state/pcaps/subdir), keep it canonical.
    local candidate="${BASE_DIR%/}/${rel}"
    case "$candidate" in
    "$CAPTURE_DIR" | "$CAPTURE_DIR"/*)
      out_dir="$candidate"
      ;;
    *)
      # Support short aliases while keeping captures under CAPTURE_DIR.
      if [[ "$rel" == pcaps ]]; then
        rel=""
      elif [[ "$rel" == pcaps/* ]]; then
        rel="${rel#pcaps/}"
      elif [[ "$rel" == state/pcaps ]]; then
        rel=""
      elif [[ "$rel" == state/pcaps/* ]]; then
        rel="${rel#state/pcaps/}"
      fi

      if [ -n "$rel" ]; then
        out_dir="${CAPTURE_DIR}/${rel}"
      else
        out_dir="${CAPTURE_DIR}"
      fi
      ;;
    esac
  fi

  local old_umask capture_root="" resolved_out_dir=""
  old_umask="$(umask)"
  umask 077
  mkdir -p "$CAPTURE_DIR"
  umask "$old_umask"
  chmod 700 "$CAPTURE_DIR" 2>/dev/null || true

  if ! _capture_resolve_existing_path capture_root "$CAPTURE_DIR"; then
    echo "[Error] Unable to resolve capture root '${CAPTURE_DIR}'." >&2
    return 1
  fi

  if ! _capture_resolve_output_path resolved_out_dir "$out_dir"; then
    echo "[Error] Unable to resolve capture output directory '${requested_out_dir}'." >&2
    return 1
  fi

  case "$resolved_out_dir" in
  "$capture_root" | "$capture_root"/*)
    out_dir="$resolved_out_dir"
    ;;
  *)
    echo "[Error] Capture output directory '${requested_out_dir}' must reside within '${CAPTURE_DIR}'." >&2
    return 1
    ;;
  esac

  old_umask="$(umask)"
  umask 077
  mkdir -p "$out_dir"
  umask "$old_umask"
  chmod 700 "$out_dir" 2>/dev/null || true
  if ! require_managed_nginx_container "start-capture"; then
    return 1
  fi
  if ! container_running "$NGINX_CONTAINER_NAME"; then
    echo "[Error] Nginx container is not running." >&2
    return 1
  fi

  if [ "$INTERACTIVE" = true ] && ! _capture_is_true "$tls_decrypt"; then
    local decrypt_choice=""
    read_with_editing "Enable TLS decrypt capture (stores TLS session keys)? [y/N]: " decrypt_choice
    decrypt_choice="$(printf '%s' "${decrypt_choice:-n}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$decrypt_choice" =~ ^(y|yes)$ ]]; then
      tls_decrypt="true"
    fi
  fi

  # Default scope if not provided
  if [ -z "$scope" ]; then
    if [ -n "$client_input" ] && [ -n "$backend_input" ]; then
      scope="clients-backends"
    elif [ -n "$client_input" ]; then
      scope="clients"
    elif [ -n "$backend_input" ]; then
      scope="backends"
    else
      scope="all"
    fi
  fi

  if [ "$INTERACTIVE" = true ]; then
    local scope_idx
    if ! choose_option scope_idx "Capture scope?" \
      "All Nginx traffic (clients and backends)" \
      "Specific backend(s)" \
      "Specific client IP(s) (any backend)" \
      "Specific client IP(s) to backend(s)"; then
      return 1
    fi
    case "$scope_idx" in
    1) scope="backends" ;;
    2) scope="clients" ;;
    3) scope="clients-backends" ;;
    *) scope="all" ;;
    esac

    if [ "$scope" = "backends" ] || [ "$scope" = "clients-backends" ]; then
      local available_backends=""
      if [ -f "$BACKEND_PORTS_FILE" ]; then
        local available_backends_lines=""
        local state_line="" state_line_no=0
        while IFS= read -r state_line || [ -n "$state_line" ]; do
          state_line_no=$((state_line_no + 1))
          [ "$state_line_no" -eq 1 ] && continue
          state_backend_ports_parse_line "$state_line" || continue
          [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
          [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
          [ -n "${STATE_BP_DOMAIN:-}" ] || continue
          available_backends_lines+="${STATE_BP_DOMAIN}"$'\n'
        done <"$BACKEND_PORTS_FILE"
        available_backends="$(printf '%s' "$available_backends_lines" | awk 'NF > 0' | sort -u | xargs)"
      fi
      if [ -z "$available_backends" ]; then
        echo "[Warn] No configured backends; falling back to client-only or full capture." >&2
        if [ "$scope" = "clients-backends" ]; then
          scope="clients"
        else
          scope="all"
        fi
      else
        echo "[Info] Available backends: $available_backends"
        read_with_editing "Enter backend domains (comma/space-separated, blank=all): " backend_input
      fi
    fi

    if [ "$scope" = "clients" ] || [ "$scope" = "clients-backends" ]; then
      read_with_editing "Enter client IPs (comma/space-separated, blank=all clients): " client_input
      if [ -z "$client_input" ] && [ "$scope" = "clients" ]; then
        scope="all"
      fi
    fi
  fi

  scope="$(printf '%s' "$scope" | tr '[:upper:]' '[:lower:]')"
  case "$scope" in
  backends | backend) scope="backends" ;;
  clients | client) scope="clients" ;;
  clients-backends | clients_backends | clientsandbackends | clients-and-backends | client-backend | client_backends)
    scope="clients-backends"
    ;;
  *) scope="all" ;;
  esac

  # Normalize target lists
  backend_input="${backend_input//,/ }"
  client_input="${client_input//,/ }"

  local -a backend_targets=()
  local -a client_hosts=()
  if [ "$scope" = "backends" ] || [ "$scope" = "clients-backends" ]; then
    local backend
    for backend in $backend_input; do
      backend="$(normalize_domain "$backend")"
      [ -n "$backend" ] || continue
      local seen=false item
      if [ ${#backend_targets[@]} -gt 0 ]; then
        for item in "${backend_targets[@]}"; do
          if [ "$item" = "$backend" ]; then
            seen=true
            break
          fi
        done
      fi
      [ "$seen" = true ] && continue
      backend_targets+=("$backend")
    done
  fi

  if [ "$scope" = "clients" ] || [ "$scope" = "clients-backends" ]; then
    local ip
    for ip in $client_input; do
      [ -n "$ip" ] || continue
      if ! is_valid_ipv4 "$ip"; then
        echo "[Error] Invalid client IP filter token: '$ip'. Use IPv4 addresses only." >&2
        return 1
      fi
      local seen=false item
      if [ ${#client_hosts[@]} -gt 0 ]; then
        for item in "${client_hosts[@]}"; do
          if [ "$item" = "$ip" ]; then
            seen=true
            break
          fi
        done
      fi
      [ "$seen" = true ] && continue
      client_hosts+=("$ip")
    done
  fi

  if [ "$scope" = "backends" ] || [ "$scope" = "clients-backends" ]; then
    if [ ${#backend_targets[@]} -eq 0 ] && [ -f "$BACKEND_PORTS_FILE" ]; then
      local state_line="" state_line_no=0
      while IFS= read -r state_line || [ -n "$state_line" ]; do
        state_line_no=$((state_line_no + 1))
        [ "$state_line_no" -eq 1 ] && continue
        state_backend_ports_parse_line "$state_line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
        local type dom
        type="${STATE_BP_RECORD_TYPE:-}"
        dom="${STATE_BP_DOMAIN:-}"
        if [ "$type" = "backend" ]; then
          local normalized exists item
          normalized="$(normalize_domain "$dom")"
          [ -n "$normalized" ] || continue
          exists=false
          if [ ${#backend_targets[@]} -gt 0 ]; then
            for item in "${backend_targets[@]}"; do
              if [ "$item" = "$normalized" ]; then
                exists=true
                break
              fi
            done
          fi
          [ "$exists" = true ] && continue
          backend_targets+=("$normalized")
        fi
      done <"$BACKEND_PORTS_FILE"
    fi
  fi

  # Adjust scope if inputs are missing
  if [ "$scope" = "clients-backends" ] && [ ${#backend_targets[@]} -eq 0 ]; then
    if [ ${#client_hosts[@]} -gt 0 ]; then
      echo "[Warn] No backends selected; falling back to client-only capture." >&2
      scope="clients"
    else
      scope="all"
    fi
  fi
  if [ "$scope" = "backends" ] && [ ${#backend_targets[@]} -eq 0 ]; then
    scope="all"
  fi
  if [ "$scope" = "clients" ] && [ ${#client_hosts[@]} -eq 0 ]; then
    scope="all"
  fi

  local -a backend_ports=()
  local -a backend_ips=()
  if [ "$scope" = "backends" ] || [ "$scope" = "clients-backends" ]; then
    if [ -f "$BACKEND_PORTS_FILE" ] && [ ${#backend_targets[@]} -gt 0 ]; then
      local state_line="" state_line_no=0
      while IFS= read -r state_line || [ -n "$state_line" ]; do
        state_line_no=$((state_line_no + 1))
        [ "$state_line_no" -eq 1 ] && continue
        state_backend_ports_parse_line "$state_line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
        local type dom backend_upstream listen_port upstream_port
        type="${STATE_BP_RECORD_TYPE:-}"
        dom="${STATE_BP_DOMAIN:-}"
        backend_upstream="${STATE_BP_BACKEND_UPSTREAM:-}"
        listen_port="${STATE_BP_LISTEN_PORT:-}"
        upstream_port="${STATE_BP_UPSTREAM_PORT:-}"
        local d_lower
        d_lower="$(normalize_domain "$dom")"
        local match=false t
        for t in "${backend_targets[@]}"; do
          if [ "$t" = "$d_lower" ]; then
            match=true
            break
          fi
        done
        [ "$match" = true ] || continue

        if [ "$type" = "backend" ]; then
          if [[ "$backend_upstream" == *:* ]]; then
            local backend_port="${backend_upstream##*:}"
            if [[ "$backend_port" =~ ^[0-9]+$ ]]; then
              backend_ports+=("$backend_port")
            fi
          fi
          if container_running "backend-$(sanitize_domain_name "$d_lower")"; then
            local ip
            ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "backend-$(sanitize_domain_name "$d_lower")" 2>/dev/null || true)
            [ -n "$ip" ] && backend_ips+=("$ip")
          fi
        elif [ "$type" = "port" ]; then
          if [[ "$listen_port" =~ ^[0-9]+$ ]]; then
            backend_ports+=("$listen_port")
          fi
          if [[ "$upstream_port" =~ ^[0-9]+$ ]]; then
            backend_ports+=("$upstream_port")
          fi
        fi
      done <"$BACKEND_PORTS_FILE"
    fi
  fi

  # Deduplicate ports, backend IPs, and client IPs
  local -a uniq_ports=()
  local -a uniq_backend_ips=()
  local -a uniq_client_ips=()
  local entry p ip
  if [ ${#backend_ports[@]} -gt 0 ]; then
    for p in "${backend_ports[@]}"; do
      local exists=false
      if [ ${#uniq_ports[@]} -gt 0 ]; then
        for entry in "${uniq_ports[@]}"; do
          if [ "$entry" = "$p" ]; then
            exists=true
            break
          fi
        done
      fi
      [ "$exists" = true ] || uniq_ports+=("$p")
    done
  fi
  if [ ${#backend_ips[@]} -gt 0 ]; then
    for ip in "${backend_ips[@]}"; do
      local exists_ip=false
      if [ ${#uniq_backend_ips[@]} -gt 0 ]; then
        for entry in "${uniq_backend_ips[@]}"; do
          if [ "$entry" = "$ip" ]; then
            exists_ip=true
            break
          fi
        done
      fi
      [ "$exists_ip" = true ] || uniq_backend_ips+=("$ip")
    done
  fi
  if [ ${#client_hosts[@]} -gt 0 ]; then
    for ip in "${client_hosts[@]}"; do
      local exists_ch=false
      if [ ${#uniq_client_ips[@]} -gt 0 ]; then
        for entry in "${uniq_client_ips[@]}"; do
          if [ "$entry" = "$ip" ]; then
            exists_ch=true
            break
          fi
        done
      fi
      [ "$exists_ch" = true ] || uniq_client_ips+=("$ip")
    done
  fi

  local -a backend_filter=()
  local -a client_filter=()
  local -a filter_args=()
  if [ ${#uniq_ports[@]} -gt 0 ]; then
    backend_filter+=("(" "port" "${uniq_ports[0]}")
    local i
    for ((i = 1; i < ${#uniq_ports[@]}; i++)); do
      backend_filter+=("or" "port" "${uniq_ports[$i]}")
    done
    backend_filter+=(")")
  fi
  if [ ${#uniq_backend_ips[@]} -gt 0 ]; then
    if [ ${#backend_filter[@]} -gt 0 ]; then
      backend_filter+=("or")
    fi
    backend_filter+=("(" "host" "${uniq_backend_ips[0]}")
    local i
    for ((i = 1; i < ${#uniq_backend_ips[@]}; i++)); do
      backend_filter+=("or" "host" "${uniq_backend_ips[$i]}")
    done
    backend_filter+=(")")
  fi

  if [ ${#uniq_client_ips[@]} -gt 0 ]; then
    client_filter+=("(" "host" "${uniq_client_ips[0]}")
    local i
    for ((i = 1; i < ${#uniq_client_ips[@]}; i++)); do
      client_filter+=("or" "host" "${uniq_client_ips[$i]}")
    done
    client_filter+=(")")
  fi

  if [ "$scope" = "clients-backends" ]; then
    if [ ${#backend_filter[@]} -gt 0 ] && [ ${#client_filter[@]} -gt 0 ]; then
      filter_args+=("(")
      filter_args+=("${client_filter[@]}")
      filter_args+=("and")
      filter_args+=("${backend_filter[@]}")
      filter_args+=(")")
    elif [ ${#client_filter[@]} -gt 0 ]; then
      filter_args=("${client_filter[@]}")
      scope="clients"
    elif [ ${#backend_filter[@]} -gt 0 ]; then
      filter_args=("${backend_filter[@]}")
      scope="backends"
    else
      scope="all"
    fi
  elif [ "$scope" = "clients" ]; then
    if [ ${#client_filter[@]} -gt 0 ]; then
      filter_args=("${client_filter[@]}")
    else
      scope="all"
    fi
  elif [ "$scope" = "backends" ]; then
    if [ ${#backend_filter[@]} -gt 0 ]; then
      filter_args=("${backend_filter[@]}")
    else
      scope="all"
    fi
  fi

  if _capture_is_true "$tls_decrypt"; then
    local decrypt_context=""
    local keylog_file=""
    decrypt_context="command=start-capture scope=${scope:-auto} backends=${backend_input:-all} clients=${client_input:-all}"
    acknowledge_tls_decrypt_capture "$decrypt_context"
    if ! enable_capture_tls_decrypt "$decrypt_context"; then
      echo "[Error] Failed to enable TLS decrypt capture mode." >&2
      return 1
    fi
    if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
      local recreate_status=0
      recreate_nginx_container "$NGINX_IMAGE" || recreate_status=$?
      if [ "$recreate_status" -ne 0 ]; then
        if [ "$recreate_status" -eq 2 ]; then
          echo "[Error] Failed to finish Nginx TLS decrypt setup after container launch; TLS decrypt state preserved because Nginx may already be running with key logging enabled." >&2
          return 1
        fi
        disable_capture_tls_decrypt "command=start-capture action=rollback"
        echo "[Error] Failed to recreate Nginx with TLS decrypt key logging enabled." >&2
        return 1
      fi
    fi
    echo "[Warn] TLS decrypt capture enabled for this session. Session keys are sensitive and stored with restricted permissions."
    if capture_tls_keylog_file keylog_file 2>/dev/null; then
      echo "[Info] TLS key log file: ${keylog_file}"
    fi
  fi

  local full_dir
  full_dir=$(cd "$out_dir" && pwd)
  local timestamp
  timestamp="$(date '+%Y%m%d_%H%M%S')"
  local pcap_file="${timestamp}_nginx.pcap"
  remove_container_and_anonymous_volumes nginx-capture >/dev/null 2>&1 || true
  local -a docker_cmd=(
    docker run -d --name nginx-capture --net=container:"$NGINX_CONTAINER_NAME"
    -v "$full_dir":/pcaps
    "$capture_image"
    tcpdump -U -i any -s0 -w "/pcaps/${pcap_file}"
  )
  if [ ${#filter_args[@]} -gt 0 ]; then
    docker_cmd+=("${filter_args[@]}")
  fi
  "${docker_cmd[@]}"

  local info_parts=()
  if [ "$scope" = "backends" ]; then
    info_parts+=("backends: ${backend_targets[*]:-all}")
  elif [ "$scope" = "clients" ]; then
    info_parts+=("clients: ${uniq_client_ips[*]:-all}")
  elif [ "$scope" = "clients-backends" ]; then
    info_parts+=("clients: ${uniq_client_ips[*]:-all}")
    info_parts+=("backends: ${backend_targets[*]:-all}")
  else
    info_parts+=("full traffic")
  fi
  info_parts+=("image: ${capture_image}")
  if _capture_is_true "$tls_decrypt"; then
    info_parts+=("tls-decrypt: enabled")
  fi
  echo "[Info] Packet capture started (scope: ${scope}; ${info_parts[*]}). Output: ${full_dir}/${pcap_file}"
}
