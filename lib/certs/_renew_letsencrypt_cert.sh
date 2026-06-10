# shellcheck shell=bash

function _renew_letsencrypt_cert() {
  local domain="${1:-}"

  if [ -z "$domain" ]; then
    echo "[Error] Missing domain for renewal" >&2
    return 1
  fi

  domain="$(normalize_domain "$domain")"
  require_valid_domain "$domain" return || return 1

  check_certbot_installed
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "${CERTS_DIR}/letsencrypt" "$ACME_WEBROOT_DIR" || return 1
  fi
  mkdir -p "${CERTS_DIR}/letsencrypt" "$ACME_WEBROOT_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "${CERTS_DIR}/letsencrypt" "$ACME_WEBROOT_DIR" || return 1
  fi

  local running_state=""
  if nginx_container_is_managed; then
    running_state="$(docker inspect -f '{{.State.Running}}' "${NGINX_CONTAINER_NAME}")"
  elif nginx_container_conflict_exists; then
    _nginx_conflict_error "renew-certs"
    return 1
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
      certbot_docker_host_user_mapping "${CERTS_DIR}/letsencrypt" "$ACME_WEBROOT_DIR"
    )"
    certbot_user_status=$?
    set -e
    if [ "$certbot_user_status" -eq 0 ]; then
      certbot_user_args=(--user "$certbot_user_mapping")
      certbot_standalone_cap_args=(--cap-add=NET_BIND_SERVICE)
    else
      return 1
    fi
  fi

  pull_image_if_autopull "$CERTBOT_IMAGE" "Certbot"

  local certbot_exit
  if [ "$running_state" = "true" ]; then
    echo "[Info] Renewing Let's Encrypt certificate for ${domain} using webroot mode..."
    update_nginx_config
    local -a certbot_cmd=(docker run "${docker_run_tty_args[@]}" --rm)
    if [ ${#certbot_user_args[@]} -gt 0 ]; then
      certbot_cmd+=("${certbot_user_args[@]}")
    fi
    certbot_cmd+=(
      -v "${CERTS_DIR}/letsencrypt:/etc/letsencrypt"
      -v "${ACME_WEBROOT_DIR}:/var/www/certbot"
      "$CERTBOT_IMAGE" certonly
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
    echo "[Info] Renewing Let's Encrypt certificate for ${domain} using standalone mode..."
    local -a certbot_cmd=(docker run "${docker_run_tty_args[@]}" --rm)
    if [ ${#certbot_user_args[@]} -gt 0 ]; then
      certbot_cmd+=("${certbot_user_args[@]}")
    fi
    if [ ${#certbot_standalone_cap_args[@]} -gt 0 ]; then
      certbot_cmd+=("${certbot_standalone_cap_args[@]}")
    fi
    certbot_cmd+=(
      -p 80:80
      -v "${CERTS_DIR}/letsencrypt:/etc/letsencrypt"
      -v "${ACME_WEBROOT_DIR}:/var/www/certbot"
      "$CERTBOT_IMAGE" certonly
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

  if [ $certbot_exit -ne 0 ]; then
    echo "[Error] Certbot renewal failed for ${domain}" >&2
    log_msg "Certbot renewal failed for ${domain} (exit ${certbot_exit})"
    return 1
  fi

  echo "[Info] Renewal completed for ${domain}"
  log_msg "Renewed Let's Encrypt certificate for ${domain}"
  return 0
}
