# shellcheck shell=bash

function domain_config_runtime_preview() {
  local candidate="$1" dir="" domain="" role="" image="" port="" network="" state="" options=""
  local actual_image="" actual_state="" runtime_file="" old_port="" old_network="" old_options=""
  local row="" certificate_rows="" number=0 cert_dir="" fingerprint="" mtls_dir="" missing=false snapshot_status=0 actual_ip="" saved_upstream=""
  for dir in "$candidate"/*; do
    [ -d "$dir/config" ] || continue
    domain="${dir##*/}"
    _domain_config_domain_selected "$domain" || continue
    role="$(domain_config_get "$dir/config" domain.csv role)" || return 1
    if [ "$role" = backend ]; then
      image="$(domain_config_get "$dir/config" backend.csv image)" || return 1
      port="$(domain_config_get "$dir/config" backend.csv container_port)" || return 1
      network="$(domain_config_get "$dir/config" backend.csv network "${DEFAULT_NETWORK:-dockistrate-net}")" || return 1
      state="$(domain_config_get "$dir/config" backend.csv state running)" || return 1
      options="$(domain_config_docker_options "$dir/config")" || return 1
      if ! backend_exists "$domain"; then
        printf '  %s: create backend %s (%s) on %s, upstream port %s\n' "$domain" "$image" "$state" "$network" "$port"
      else
        runtime_file="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime/backend.csv"
        actual_image=""; actual_state=""; old_port=""; old_network=""; missing=false
        if [ -f "$runtime_file" ]; then
          actual_image="$(_domain_runtime_get "$runtime_file" image)" || return 1
          actual_state="$(_domain_runtime_get "$runtime_file" state)" || return 1
          old_port="$(_domain_runtime_get "$runtime_file" container_port)" || return 1
          old_network="$(_domain_runtime_get "$runtime_file" network)" || return 1
        fi
        if [ "${SKIP_DOCKER_CHECKS:-false}" != true ]; then
          snapshot_status=0
          _backend_container_snapshot "$domain" 2>/dev/null || snapshot_status=$?
          if [ "$snapshot_status" -eq 0 ]; then
            actual_image="$BACKEND_CONTAINER_IMAGE"
            actual_state=stopped
            [ "$BACKEND_CONTAINER_STATUS" != running ] || actual_state=running
            _domain_runtime_snapshot_has_network "$network" || old_network=""
            if [ "$actual_state" = running ]; then
              actual_ip="$(_backend_snapshot_network_ip "$network")" || return 1
              saved_upstream=""; number=0
              while IFS= read -r row || [ -n "$row" ]; do
                number=$((number + 1)); [ "$number" -eq 1 ] && continue
                state_backend_ports_parse_line "$row" || return 1
                if [ "$STATE_BP_RECORD_TYPE" = backend ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
                  saved_upstream="$STATE_BP_BACKEND_UPSTREAM"; break
                fi
              done <"$BACKEND_PORTS_FILE"
              if [ -n "$actual_ip" ] && [ "$saved_upstream" != "$actual_ip:$port" ]; then
                printf '  %s: refresh backend address to %s:%s\n' "$domain" "$actual_ip" "$port"
              fi
            fi
          elif [ "$snapshot_status" -eq 2 ] && _domain_runtime_absent_backend_is_replaceable "$domain"; then
            missing=true
            printf '  %s: recreate absent backend with %s (%s) on %s, upstream port %s\n' "$domain" "$image" "$state" "$network" "$port"
          else
            echo "[Error] Cannot verify the managed backend for $domain; explicit identity repair is required." >&2
            return 1
          fi
        fi
        old_options="$(get_backend_docker_opts "backend:${domain}")" || return 1
        if [ "$missing" = true ]; then
          :
        elif [ "$actual_image" != "$image" ] || [ "$old_options" != "$options" ]; then
          printf '  %s: replace backend with %s (%s)\n' "$domain" "$image" "$state"
        elif [ "$actual_state" != "$state" ]; then
          printf '  %s: set backend state to %s\n' "$domain" "$state"
        fi
        if [ "$missing" != true ]; then
          [ "$old_network" = "$network" ] || printf '  %s: select backend network %s\n' "$domain" "$network"
          [ "$old_port" = "$port" ] || printf '  %s: use upstream port %s\n' "$domain" "$port"
        fi
      fi
    fi
    certificate_rows="$(_domain_csv_rows "$dir/config/certificates.csv")" || return 1
    if [ -n "$certificate_rows" ]; then
      while IFS= read -r row || [ -n "$row" ]; do
        csv_parse_line "$row" || return 1
        local cert_id="${CSV_FIELDS[0]}" provider="${CSV_FIELDS[1]}" cert_port="${CSV_FIELDS[2]}" source_cert="" source_key=""
        if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
          source_cert="$(domain_config_certificate_option "$dir/config" "$cert_id" source_fullchain)" || return 1
          source_key="$(domain_config_certificate_option "$dir/config" "$cert_id" source_privkey)" || return 1
        else
          source_cert="${CSV_FIELDS[3]}"; source_key="${CSV_FIELDS[4]}"
        fi
        domain_config_certificate_dir cert_dir "$domain" "$cert_id" || return 1
        fingerprint="$(_domain_cert_fingerprint "$cert_id" "$provider" "$cert_port" "$source_cert" "$source_key")" || return 1
        if ! _domain_cert_matches_specification "$cert_dir" "$fingerprint"; then
          printf '  %s: provision %s certificate %s\n' "$domain" "$provider" "$cert_id"
        fi
      done <<<"$certificate_rows"
    fi
    if [ "$(domain_config_get "$dir/config" mtls.csv enabled no)" = yes ]; then
      domain_config_mtls_dir mtls_dir "$domain" || return 1
      if [ ! -f "$mtls_dir/ca.crt" ] || [ ! -f "$mtls_dir/ca.key" ] || [ ! -f "$mtls_dir/ca.crl" ]; then
        printf '  %s: provision mTLS authority/trust material\n' "$domain"
      fi
    fi
  done
}

function domain_config_runtime_matches() {
  local candidate="$1" changes="" expected="" actual=""
  changes="$(domain_config_runtime_preview "$candidate")" || return 1
  [ -z "$changes" ] || return 1
  [ -f "$NGINX_CONFIG_DIR/nginx.conf" ] || return 1
  _domain_config_generated_ready "$candidate" || return 1
  if [ "${SKIP_DOCKER_CHECKS:-false}" != true ]; then
    nginx_container_is_managed && container_running "$NGINX_CONTAINER_NAME" || return 1
    expected="$(get_all_mapped_port_bindings | tr ' ' '\n' | LC_ALL=C sort -u | xargs)" || return 1
    actual="$(container_published_port_bindings "$NGINX_CONTAINER_NAME" | tr ' ' '\n' | LC_ALL=C sort -u | xargs)" || return 1
    [ "$expected" = "$actual" ] || return 1
  fi
}

# Status checks only the accepted snapshot. Drafts and Docker tag updates do
# not change the meaning of an already applied image reference.
function domain_config_backend_runtime_drift() {
  local domain="$1" config="${DOMAINS_DIR:-${STATE_DIR}/domains}/$1/runtime/applied"
  local desired="" network="" port="" options="" actual="" row="" number=0 found=false
  [ "${SKIP_DOCKER_CHECKS:-false}" != true ] || return 1
  [ -f "$config/backend.csv" ] || return 1
  [ "$(domain_config_get "$config" domain.csv role)" = backend ] || return 1
  _backend_container_snapshot "$domain" 2>/dev/null || return 0
  desired="$(domain_config_get "$config" backend.csv image)" || return 0
  [ "$BACKEND_CONTAINER_IMAGE" = "$desired" ] || return 0
  desired="$(domain_config_get "$config" backend.csv state running)" || return 0
  actual=stopped; [ "$BACKEND_CONTAINER_STATUS" != running ] || actual=running
  [ "$actual" = "$desired" ] || return 0
  network="$(domain_config_get "$config" backend.csv network "${DEFAULT_NETWORK:-dockistrate-net}")" || return 0
  _domain_runtime_snapshot_has_network "$network" || return 0
  options="$(domain_config_docker_options "$config")" || return 0
  [ "$options" = "$(get_backend_docker_opts "backend:$domain")" ] || return 0
  if [ "$actual" = running ]; then
    actual="$(_backend_snapshot_network_ip "$network")" || return 0
    [ -n "$actual" ] || return 0
    port="$(domain_config_get "$config" backend.csv container_port)" || return 0
    while IFS= read -r row || [ -n "$row" ]; do
      number=$((number + 1)); [ "$number" -eq 1 ] && continue
      state_backend_ports_parse_line "$row" || return 0
      if [ "$STATE_BP_RECORD_TYPE" = backend ] && [ "$STATE_BP_DOMAIN" = "$domain" ]; then
        found=true
        [ "$STATE_BP_BACKEND_UPSTREAM" = "$actual:$port" ] || return 0
        [ "$STATE_BP_NETWORK" = "$network" ] || return 0
        break
      fi
    done <"$BACKEND_PORTS_FILE"
    [ "$found" = true ] || return 0
  fi
  return 1
}
