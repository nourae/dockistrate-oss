# shellcheck shell=bash

function domain_config_validate_nginx_candidate() {
  local projection="${1:-}" line="" skip_value=false retain_value=false
  local -a args=()
  domain_config_active || return 0
  [ "${SKIP_DOCKER_CHECKS:-}" != true ] || return 0
  _nginx_verify_certificate_projection "$projection" || return 1
  _domain_runtime_ensure_network proxy.dockistrate.invalid "$DEFAULT_NETWORK" || return 1
  # Reuse operator mounts, environment and runtime capabilities. Validation
  # never publishes ports, takes a persistent name, or claims the serving
  # container's endpoint addresses/aliases while that container is still live.
  if [ -n "${NGINX_DOCKER_OPTS:-}" ]; then
    local parsed=""
    _parse_docker_opts_capture_lines parsed "$NGINX_DOCKER_OPTS" "Nginx validation options" || return 1
    while IFS= read -r line; do
      if [ "$skip_value" = true ]; then skip_value=false; continue; fi
      if [ "$retain_value" = true ]; then args+=("$line"); retain_value=false; continue; fi
      case "$line" in
      --publish | -p | --name | --cidfile | --restart | --ip | --ip6 | --mac-address | --link-local-ip | --network-alias | --net-alias) skip_value=true ;;
      --publish=* | -p?* | --name=* | --cidfile=* | --restart=* | --publish-all | --publish-all=* | -P | --detach | --detach=* | -d | --rm | --rm=* | \
        --ip=* | --ip6=* | --mac-address=* | --link-local-ip=* | --network-alias=* | --net-alias=*) ;;
      *)
        args+=("$line")
        if _docker_opts_option_allows_separate_value "$line"; then retain_value=true; fi
        ;;
      esac
    done < <(printf '%s' "$parsed")
  fi
  pull_image_if_autopull "$NGINX_IMAGE" Nginx || return 1
  local -a command=(docker run --rm)
  if [ "${#args[@]}" -gt 0 ]; then command+=("${args[@]}"); fi
  # Override boolean shorthand bundles too (-dit, -d=true). Docker must wait
  # for nginx -t and report its exit status without an interactive terminal.
  command+=(--detach=false --interactive=false --tty=false)
  command+=(-v "$NGINX_CONFIG_DIR:$NGINX_CONTAINER_CONF_ROOT:ro" \
    -v "$projection:/etc/letsencrypt:ro" \
    -v "$ACME_WEBROOT_DIR:/var/www/certbot:ro" \
    --network "$DEFAULT_NETWORK" "$NGINX_IMAGE" nginx -t -c "$NGINX_CONTAINER_MAIN_CONF")
  if ! "${command[@]}"; then
    echo '[Error] Candidate Nginx configuration failed validation; active configuration will be restored.' >&2
    return 1
  fi
}
