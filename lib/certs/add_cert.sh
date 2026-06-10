# shellcheck shell=bash

function add_cert() {
  local domain="${1:-}"
  local port_suffix="${2:-443}"
  local cert_choice="${3:-}"
  local upload_fc="${4:-}"
  local upload_pk="${5:-}"
  local caller_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
  local started_txn=false
  [ -z "$domain" ] && {
    echo "[Usage] add-cert <domain> [port_suffix] [selfsigned|letsencrypt|upload] [fullchain] [privkey]"
    exit 1
  }
  require_valid_domain "$domain"
  require_valid_port "$port_suffix"

  domain="$(normalize_domain "$domain")"

  if [ -z "$cert_choice" ]; then
    if [ "$INTERACTIVE" = true ]; then
      read_with_editing "Certificate type? (s)elf-signed, (l)etsencrypt, (u)pload? [s/l/u]: " cert_choice
    else
      cert_choice="s"
    fi
  fi

  local cert_type
  local cert_folder
  local created_ok=false

  case "$cert_choice" in
  [Ss] | selfsigned)
    cert_type="selfsigned"
    ;;
  [Ll] | letsencrypt)
    cert_type="letsencrypt"
    check_certbot_installed
    ;;
  [Uu] | upload)
    cert_type="custom"
    if [ -z "$upload_fc" ] || [ -z "$upload_pk" ]; then
      if [ "$INTERACTIVE" = true ]; then
        prompt_input_valid upload_fc "Path to existing fullchain.pem" "" file_exists
        prompt_input_valid upload_pk "Path to existing privkey.pem" "" file_exists
      else
        echo "[Error] fullchain and privkey paths required for upload type." >&2
        return 1
      fi
    fi
    if [ ! -f "$upload_fc" ] || [ ! -f "$upload_pk" ]; then
      echo "[Error] Provided cert/key paths invalid." >&2
      return 1
    fi
    ;;
  *)
    echo "[Error] Invalid choice. Aborting." >&2
    return 1
    ;;
  esac

  if ! _config_begin_transaction_if_needed started_txn "add_cert_${domain}_${port_suffix}" "$CERTS_DIR" "$ACME_WEBROOT_DIR"; then
    exit 1
  fi

  case "$cert_choice" in
  [Ss] | selfsigned)
    cert_folder="${CERTS_DIR}/${cert_type}/live/${domain}_${port_suffix}"
    local old_umask
    old_umask="$(umask)"
    umask 077
    mkdir -p "$cert_folder"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -keyout "${cert_folder}/privkey.pem" \
      -out "${cert_folder}/fullchain.pem" \
      -subj "/CN=${domain}" 2>/dev/null
    local openssl_status=$?
    umask "$old_umask"
    chmod 750 "$cert_folder" 2>/dev/null || true
    if [ $openssl_status -eq 0 ]; then
      # Ensure Nginx inside the container can read the certificate while keeping
      # the private key owner-only.
      chmod 600 "${cert_folder}/privkey.pem"
      chmod 640 "${cert_folder}/fullchain.pem"
      echo "[Info] Self-signed cert saved to $cert_folder."
      created_ok=true
      create_backup "" "AddCert_SelfSigned_${domain}"
    else
      echo "[Error] Failed generating self-signed cert." >&2
      _rollback_handler
    fi
    ;;
  [Ll] | letsencrypt)
    cert_folder="${CERTS_DIR}/${cert_type}/live/${domain}_${port_suffix}"
    echo "[Info] Generating Let’s Encrypt cert for ${domain}..."

    local running_state=""
    if nginx_container_is_managed; then
      running_state="$(docker inspect -f '{{.State.Running}}' "${NGINX_CONTAINER_NAME}")"
    elif nginx_container_conflict_exists; then
      _nginx_conflict_error "add-cert"
      return 1
    fi

    if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
      runtime_state_paths_guard_if_declared "${CERTS_DIR}/${cert_type}" "$ACME_WEBROOT_DIR" || return 1
    fi
    mkdir -p "${CERTS_DIR}/${cert_type}" "$ACME_WEBROOT_DIR"
    if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
      runtime_state_paths_guard_if_declared "${CERTS_DIR}/${cert_type}" "$ACME_WEBROOT_DIR" || return 1
    fi

    local -a docker_run_tty_args=("-i")
    if [[ -t 1 ]]; then
      docker_run_tty_args+=("-t")
    fi

    local certbot_user_mapping="" certbot_user_status=0
    local -a certbot_user_args=()
    local -a certbot_standalone_cap_args=()
    if _certbot_docker_is_darwin_host; then
      set +e
      certbot_user_mapping="$(
        trap - ERR EXIT
        certbot_docker_host_user_mapping "${CERTS_DIR}/${cert_type}" "$ACME_WEBROOT_DIR"
      )"
      certbot_user_status=$?
      set -e
      if [ "$certbot_user_status" -eq 0 ]; then
        certbot_user_args=(--user "$certbot_user_mapping")
        certbot_standalone_cap_args=(--cap-add=NET_BIND_SERVICE)
      else
        transaction_return_failure || true
        return 1
      fi
    fi

    pull_image_if_autopull "$CERTBOT_IMAGE" "Certbot"

    local certbot_exit
    if [ "$running_state" = "true" ]; then
      echo "[Info] Using webroot mode for Certbot (no downtime)..."
      # Ensure challenge files can be served
      update_nginx_config
      local -a certbot_cmd=(docker run "${docker_run_tty_args[@]}" --rm)
      if [ ${#certbot_user_args[@]} -gt 0 ]; then
        certbot_cmd+=("${certbot_user_args[@]}")
      fi
      certbot_cmd+=(
        -v "${CERTS_DIR}/${cert_type}:/etc/letsencrypt"
        -v "${ACME_WEBROOT_DIR}:/var/www/certbot"
        "${CERTBOT_IMAGE}" certonly
        --webroot --webroot-path /var/www/certbot
        --non-interactive
        --agree-tos
        --no-eff-email
        --register-unsafely-without-email
        -d "${domain}"
      )
      "${certbot_cmd[@]}"
      certbot_exit=$?
    else
      echo "[Info] Nginx not running, using standalone mode..."
      local -a certbot_cmd=(docker run "${docker_run_tty_args[@]}" --rm)
      if [ ${#certbot_user_args[@]} -gt 0 ]; then
        certbot_cmd+=("${certbot_user_args[@]}")
      fi
      if [ ${#certbot_standalone_cap_args[@]} -gt 0 ]; then
        certbot_cmd+=("${certbot_standalone_cap_args[@]}")
      fi
      certbot_cmd+=(
        -p 80:80
        -v "${CERTS_DIR}/${cert_type}:/etc/letsencrypt"
        -v "${ACME_WEBROOT_DIR}:/var/www/certbot"
        "${CERTBOT_IMAGE}" certonly
        --standalone
        --non-interactive
        --agree-tos
        --no-eff-email
        --register-unsafely-without-email
        -d "${domain}"
      )
      "${certbot_cmd[@]}"
      certbot_exit=$?
    fi

    if [ $certbot_exit -eq 0 ]; then
      local default_le_dir="${CERTS_DIR}/${cert_type}/live/${domain}"
      if [ -d "$default_le_dir" ]; then
        local old_umask
        old_umask="$(umask)"
        umask 077
        mkdir -p "$cert_folder"
        umask "$old_umask"
        if ! copy_file_atomic "$default_le_dir/fullchain.pem" "${cert_folder}/fullchain.pem" 640 ||
          ! copy_file_atomic "$default_le_dir/privkey.pem" "${cert_folder}/privkey.pem" 600; then
          echo "[Error] Failed to place Let’s Encrypt cert files in $cert_folder." >&2
          _rollback_handler
        fi
        chmod 750 "$cert_folder" 2>/dev/null || true
        echo "[Info] Let’s Encrypt cert placed in $cert_folder."
        created_ok=true
        create_backup "" "AddCert_LE_${domain}"
      else
        echo "[Error] Let’s Encrypt dir not found: $default_le_dir" >&2
        _rollback_handler
      fi
    else
      echo "[Error] Certbot process failed." >&2
      _rollback_handler
    fi
    ;;
  [Uu] | upload)
    cert_folder="${CERTS_DIR}/${cert_type}/live/${domain}_${port_suffix}"
    local old_umask
    old_umask="$(umask)"
    umask 077
    mkdir -p "$cert_folder"
    umask "$old_umask"
    if ! copy_file_atomic "$upload_fc" "${cert_folder}/fullchain.pem" 640 ||
      ! copy_file_atomic "$upload_pk" "${cert_folder}/privkey.pem" 600; then
      echo "[Error] Failed to copy uploaded certificate files into $cert_folder." >&2
      _rollback_handler
    fi
    chmod 750 "$cert_folder" 2>/dev/null || true
    echo "[Info] Copied cert/key to $cert_folder."
    created_ok=true
    create_backup "" "AddCert_Upload_${domain}"
    ;;
  esac

  if [ "$created_ok" = true ]; then
    local prev_skip="${SKIP_UPDATE_NGINX_CONFIG:-}"
    SKIP_UPDATE_NGINX_CONFIG=true

    # Convenience: enable HTTPS mapping and HTTP redirect for this domain
    if [ "${CERT_AUTOCONFIG_DISABLED:-}" != "1" ] && backend_exists "$domain" && [ -f "$BACKEND_PORTS_FILE" ]; then
      local backend_upstream=""
      local state_line="" state_line_no=0
      while IFS= read -r state_line || [ -n "$state_line" ]; do
        state_line_no=$((state_line_no + 1))
        [ "$state_line_no" -eq 1 ] && continue
        state_backend_ports_parse_line "$state_line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
        if [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] &&
          [ "${STATE_BP_DOMAIN:-}" = "$domain" ]; then
          backend_upstream="${STATE_BP_BACKEND_UPSTREAM:-}"
          break
        fi
      done <"$BACKEND_PORTS_FILE"
      if [ -n "$backend_upstream" ]; then
        local backend_ipport http_port upstream_port https_port
        backend_ipport="$backend_upstream"
        http_port=""
        state_line_no=0
        while IFS= read -r state_line || [ -n "$state_line" ]; do
          state_line_no=$((state_line_no + 1))
          [ "$state_line_no" -eq 1 ] && continue
          state_backend_ports_parse_line "$state_line" || continue
          [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
          if [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] &&
            [ "${STATE_BP_DOMAIN:-}" = "$domain" ] &&
            [ "${STATE_BP_PROTOCOL:-}" = "http" ]; then
            http_port="${STATE_BP_LISTEN_PORT:-}"
            break
          fi
        done <"$BACKEND_PORTS_FILE"
        upstream_port="${backend_ipport##*:}"
        [ -n "$http_port" ] || http_port="80"
        [ -n "$upstream_port" ] || upstream_port="80"
        https_port="$port_suffix"

        local cert_rel
        relativize_cert_dir cert_rel "$cert_folder"

        # Ensure HTTPS mapping exists (do nothing if already present)
        local has_https_mapping="false"
        state_line_no=0
        while IFS= read -r state_line || [ -n "$state_line" ]; do
          state_line_no=$((state_line_no + 1))
          [ "$state_line_no" -eq 1 ] && continue
          state_backend_ports_parse_line "$state_line" || continue
          [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
          if [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] &&
            [ "${STATE_BP_DOMAIN:-}" = "$domain" ] &&
            [ "${STATE_BP_LISTEN_PORT:-}" = "$https_port" ] &&
            [ "${STATE_BP_PROTOCOL:-}" = "https" ]; then
            has_https_mapping="true"
            break
          fi
        done <"$BACKEND_PORTS_FILE"
        if [ "$has_https_mapping" != "true" ]; then
          add_port_mapping "$domain" "$https_port" "$upstream_port" "https" "$cert_rel" "no"
        fi

        # Ensure HTTP mapping exists before setting redirect
        local has_http_mapping="false"
        state_line_no=0
        while IFS= read -r state_line || [ -n "$state_line" ]; do
          state_line_no=$((state_line_no + 1))
          [ "$state_line_no" -eq 1 ] && continue
          state_backend_ports_parse_line "$state_line" || continue
          [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
          if [ "${STATE_BP_RECORD_TYPE:-}" = "port" ] &&
            [ "${STATE_BP_DOMAIN:-}" = "$domain" ] &&
            [ "${STATE_BP_LISTEN_PORT:-}" = "$http_port" ]; then
            has_http_mapping="true"
            break
          fi
        done <"$BACKEND_PORTS_FILE"
        if [ "$has_http_mapping" != "true" ]; then
          add_port_mapping "$domain" "$http_port" "$upstream_port" "http" "none" "no"
        fi

        # Default redirect target is the HTTPS port, allow custom input in interactive mode
        local redirect_to_port="$https_port" enable_redirect="yes"
        if [ "$INTERACTIVE" = true ]; then
          read_yes_no_with_default enable_redirect "Redirect HTTP port ${http_port} to HTTPS? [Y/n]: " "yes"
          if [ "$enable_redirect" = "no" ]; then
            enable_redirect="no"
          else
            local custom_port=""
            read_with_editing "Redirect target port [${redirect_to_port}]: " custom_port "$redirect_to_port"
            if [ -n "$custom_port" ]; then
              if is_valid_port "$custom_port"; then
                redirect_to_port="$custom_port"
              else
                echo "[Warn] Invalid port '${custom_port}', keeping ${redirect_to_port}." >&2
              fi
            fi
          fi
        fi

        if [ "$enable_redirect" = "yes" ]; then
          set_port_redirect "$domain" "$http_port" "on" "301:${redirect_to_port}"
        fi
      fi
    fi

    if [ "$prev_skip" = "true" ]; then
      SKIP_UPDATE_NGINX_CONFIG="true"
    else
      unset SKIP_UPDATE_NGINX_CONFIG
    fi

    if [ "$caller_skip_update" = "true" ]; then
      _config_end_transaction_if_started "$started_txn"
      return 0
    fi

    update_nginx_config
    _config_end_transaction_if_started "$started_txn"
  fi
}
