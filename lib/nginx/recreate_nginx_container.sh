# shellcheck shell=bash

function _ensure_nginx_mount_sources() {
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$NGINX_CONFIG_DIR" "nginx config directory" || return 1
  fi
  if [ -f "$NGINX_CONFIG_DIR" ]; then
    echo "[Warn] Expected directory but found file at ${NGINX_CONFIG_DIR}; recreating." >&2
    rm -f "$NGINX_CONFIG_DIR"
  fi
  mkdir -p "$NGINX_CONFIG_DIR"
  if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
    runtime_state_path_guard_if_declared "$NGINX_CONFIG_DIR" "nginx config directory" || return 1
  fi

  if [ -f "$NGINX_HTTP_CONF_DIR" ]; then
    echo "[Warn] Expected directory but found file at ${NGINX_HTTP_CONF_DIR}; recreating." >&2
    rm -f "$NGINX_HTTP_CONF_DIR"
  fi
  if [ -f "$NGINX_STREAM_CONF_DIR" ]; then
    echo "[Warn] Expected directory but found file at ${NGINX_STREAM_CONF_DIR}; recreating." >&2
    rm -f "$NGINX_STREAM_CONF_DIR"
  fi
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" || return 1
  fi
  mkdir -p "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" || return 1
  fi

  if [ -d "${NGINX_CONFIG_DIR}/nginx.conf" ]; then
    echo "[Warn] Expected file but found directory at ${NGINX_CONFIG_DIR}/nginx.conf; regenerating." >&2
    rm -rf "${NGINX_CONFIG_DIR}/nginx.conf"
  fi
  if [ ! -f "${NGINX_CONFIG_DIR}/nginx.conf" ]; then
    create_nginx_config
  fi
}

function recreate_nginx_container() {
  local image
  image="$(normalize_nginx_image "${1:-$NGINX_IMAGE}")"
  local capture_tls_enabled="false" keylog_host_dir="" keylog_file="" keylog_name=""
  local keylog_dir_mode="700" keylog_file_mode="600"
  if declare -F capture_tls_decrypt_enabled >/dev/null 2>&1 && capture_tls_decrypt_enabled; then
    capture_tls_enabled="true"
    if declare -F capture_tls_keylog_permissions >/dev/null 2>&1; then
      capture_tls_keylog_permissions keylog_dir_mode keylog_file_mode || true
    fi
    if ! capture_tls_keylog_host_dir keylog_host_dir; then
      echo "[Error] Unable to resolve TLS key log directory." >&2
      return 1
    fi
    if ! capture_tls_keylog_file keylog_file; then
      echo "[Error] Refusing to recreate Nginx with invalid TLS decrypt state." >&2
      return 1
    fi
  fi
  if ! ensure_no_nginx_container_conflict "recreate-nginx-container"; then
    return 1
  fi
  local binding_list
  local -a mapped_bindings=()
  if [ "$#" -ge 2 ]; then
    binding_list="${2:-}"
  else
    binding_list="$(get_all_mapped_port_bindings || true)"
  fi
  if [ -n "$binding_list" ]; then
    read -r -a mapped_bindings <<<"$binding_list"
  fi

  local -a port_args=()
  if [ ${#mapped_bindings[@]} -gt 0 ]; then
    local binding b_port b_proto
    for binding in "${mapped_bindings[@]}"; do
      b_port="${binding%%/*}"
      b_proto="${binding##*/}"
      port_args+=("-p" "${b_port}:${b_port}/${b_proto}")
    done
  fi

  ensure_network_exists "$DEFAULT_NETWORK"
  _ensure_nginx_mount_sources || return 1
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$ACME_WEBROOT_DIR" "$CERTS_DIR" || return 1
  fi
  mkdir -p "$ACME_WEBROOT_DIR"
  mkdir -p "$CERTS_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$ACME_WEBROOT_DIR" "$CERTS_DIR" || return 1
  fi

  local current_bindings=""
  if nginx_container_is_managed && container_running "$NGINX_CONTAINER_NAME"; then
    current_bindings="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | xargs)"
  fi

  if [ ${#mapped_bindings[@]} -gt 0 ]; then
    local binding b_port b_proto already_published
    for binding in "${mapped_bindings[@]}"; do
      b_port="${binding%%/*}"
      b_proto="${binding##*/}"
      already_published=false
      if [ -n "$current_bindings" ]; then
        case " $current_bindings " in
        *" $binding "*) already_published=true ;;
        esac
      fi
      if [ "$already_published" != "true" ]; then
        if ! assert_host_port_available_or_fail "$b_port" "$b_proto" "" "" "true"; then
          return 1
        fi
      fi
    done
  fi

  pull_image_if_autopull "$image" "Nginx"
  local -a capture_tls_args=()
  if [ "$capture_tls_enabled" = "true" ]; then
    if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
      runtime_state_paths_guard_if_declared "$keylog_host_dir" "$keylog_file" || return 1
    fi
    mkdir -p "$keylog_host_dir"
    if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
      runtime_state_paths_guard_if_declared "$keylog_host_dir" "$keylog_file" || return 1
    fi
    chmod "$keylog_dir_mode" "$keylog_host_dir" 2>/dev/null || true
    if [ -f "$keylog_file" ]; then
      chmod "$keylog_file_mode" "$keylog_file" 2>/dev/null || true
    fi
    keylog_name="$(basename "$keylog_file")"
    if ! ensure_sslkeylog_library "$image"; then
      return 1
    fi
    capture_tls_args+=("-v" "${keylog_host_dir}:${NGINX_CAPTURE_KEYS_DIR}")
    capture_tls_args+=("-v" "${SSLKEYLOG_LIB_BUILD_FILE}:${NGINX_SSLKEYLOG_LIB_PATH}:ro")
    capture_tls_args+=("-e" "SSLKEYLOGFILE=${NGINX_CAPTURE_KEYS_DIR}/${keylog_name}")
    capture_tls_args+=("-e" "LIBSSL_SSLKEYLOGFILE=${NGINX_CAPTURE_KEYS_DIR}/${keylog_name}")
    capture_tls_args+=("-e" "LD_PRELOAD=${NGINX_SSLKEYLOG_LIB_PATH}")
  fi

  if nginx_container_is_managed; then
    _nginx_mark_runtime_rollback_needed
    remove_container_and_anonymous_volumes "$NGINX_CONTAINER_NAME" &>/dev/null || true
  fi

  local ports_display=""
  if [ ${#mapped_bindings[@]} -gt 0 ]; then
    ports_display="${mapped_bindings[*]}"
  fi

  echo "[Info] Creating Nginx container with published ports: ${ports_display}"

  local normalized_nginx_docker_opts="${NGINX_DOCKER_OPTS:-}"
  if [ -n "$normalized_nginx_docker_opts" ]; then
    if ! normalized_nginx_docker_opts="$(normalize_docker_opts_for_storage "$normalized_nginx_docker_opts" "saved nginx docker options" "nginx")"; then
      return 1
    fi
  fi

  local -a nginx_docker_args=()
  if [ -n "$normalized_nginx_docker_opts" ]; then
    local docker_opts_lines=""
    if ! docker_opts_lines="$(_parse_docker_opts_to_lines "$normalized_nginx_docker_opts" "saved nginx docker options")"; then
      return 1
    fi
    if [ -n "$docker_opts_lines" ]; then
      while IFS= read -r docker_arg_line; do
        nginx_docker_args+=("$docker_arg_line")
      done <<<"$docker_opts_lines"
    fi
  fi

  local xtrace_state=""
  if [ -n "$normalized_nginx_docker_opts" ]; then
    xtrace_disable xtrace_state
  fi

  local -a docker_run_cmd=(docker run -d --name "${NGINX_CONTAINER_NAME}")
  if [ ${#nginx_docker_args[@]} -gt 0 ]; then
    docker_run_cmd+=("${nginx_docker_args[@]}")
  fi
  docker_run_cmd+=("--label" "${DOCKISTRATE_MANAGED_LABEL_KEY}=true")
  docker_run_cmd+=("--label" "${DOCKISTRATE_ROLE_LABEL_KEY}=${DOCKISTRATE_ROLE_PROXY}")
  docker_run_cmd+=("--label" "${DOCKISTRATE_STATE_DIR_LABEL_KEY}=$(_nginx_expected_state_dir_label)")
  # Bash 3 + set -u: avoid expanding empty arrays directly.
  if [ ${#port_args[@]} -gt 0 ]; then
    docker_run_cmd+=("${port_args[@]}")
  fi
  docker_run_cmd+=("-v" "${NGINX_CONFIG_DIR}:${NGINX_CONTAINER_CONF_ROOT}:ro")
  docker_run_cmd+=("-v" "${CERTS_DIR}:/etc/letsencrypt:ro")
  if [ ${#capture_tls_args[@]} -gt 0 ]; then
    docker_run_cmd+=("${capture_tls_args[@]}")
  fi
  docker_run_cmd+=("-v" "${ACME_WEBROOT_DIR}:/var/www/certbot:ro")
  docker_run_cmd+=("--network" "$DEFAULT_NETWORK")
  docker_run_cmd+=("$image" "nginx" "-g" "daemon off;" "-c" "${NGINX_CONTAINER_MAIN_CONF}")
  if ! nginx_container_is_managed; then
    _nginx_mark_runtime_rollback_needed
  fi
  if ! "${docker_run_cmd[@]}"; then
    if [ -n "$normalized_nginx_docker_opts" ]; then
      xtrace_restore "$xtrace_state"
    fi
    return 1
  fi
  if [ -n "$normalized_nginx_docker_opts" ]; then
    xtrace_restore "$xtrace_state"
  fi

  if ! add_nginx_networks; then
    return 2
  fi

  log_msg "Recreated Nginx container with ports: ${ports_display}"
}

# Reload the running Nginx container to apply configuration changes.
