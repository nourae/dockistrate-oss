# shellcheck shell=bash

function prompt_args_postprocess() {
  local CMD="$1"
  local args=()
  if [ "${#PROMPT_ARGS_COLLECTED[@]}" -gt 0 ]; then
    args=("${PROMPT_ARGS_COLLECTED[@]}")
  fi

  case "$CMD" in
  list-security-rules)
    if [ "${args[0]:-__ALL__}" = __ALL__ ] || [ -z "${args[0]:-}" ]; then
      args=()
    else
      args=("$(normalize_domain "${args[0]}")")
    fi
    ;;
  restore-backup)
    local restore_details="${args[1]:-}"
    args=("${args[0]:-}")
    [ -z "$restore_details" ] || args+=(--backend-details "$restore_details")
    ;;
  init-domain-config)
    args=("${args[0]:-}" --kind "${args[1]:-backend}")
    ;;
  apply-domain-config)
    local domain_config_action="${args[1]:-preview}"
    args=("${args[0]:-}")
    if [ "$domain_config_action" = preview ]; then
      args+=(--dry-run)
    elif [ "$domain_config_action" != apply ]; then
      echo '[Error] Select review or apply for the domain configuration.' >&2
      return 1
    fi
    ;;
  migrate-state)
    local migration_action="${args[0]:-preview}" backend_details="${args[1]:-}"
    args=()
    if [ "$migration_action" = preview ]; then
      args+=(--dry-run)
    elif [ "$migration_action" != apply ]; then
      echo '[Error] Select review or apply for the state migration.' >&2
      return 1
    fi
    [ -z "$backend_details" ] || args+=(--backend-details "$backend_details")
    ;;
  esac

  if [ "$CMD" = update-backend ]; then
    # The picker uses sentinels; the backend command uses blank to keep these
    # values. Docker options retain their separate keep/clear intent handling.
    local backend_arg_index
    for backend_arg_index in 1 2 4; do
      if [ "${args[$backend_arg_index]:-}" = __DEFAULT__ ]; then
        args[$backend_arg_index]=""
      fi
    done
    if [ "${#args[@]}" -eq 6 ] && [ -z "${args[5]:-}" ]; then
      # Preserve the existing managed-backend picker argument contract.
      args=("${args[@]:0:5}")
    fi
  fi

  if [[ "$CMD" == "add-path-option" && ${#args[@]} -ge 3 ]]; then
    local ws_choice="${args[3]:-}" redirect_choice="${args[4]:-}" header_choice="${args[5]:-}"
    local match_choice="${args[6]:-}" priority_choice="${args[7]:-}" target_choice="${args[8]:-}"
    local rewrite_choice="${args[9]:-}" reason_choice="${args[10]:-}" loc_choice="${args[11]:-}"
    args=("${args[0]}" "${args[1]}" "${args[2]}")
    if [ -n "$ws_choice" ] && [ "$ws_choice" != "inherit" ]; then
      args+=(--ws "$ws_choice")
    fi
    if [ -n "$redirect_choice" ] && [ "$redirect_choice" != "inherit" ]; then
      args+=(--redirect "$redirect_choice")
    fi
    if [ -n "$header_choice" ] && [ "$header_choice" != "none" ]; then
      args+=(--headers "$header_choice")
    fi
    if [ -n "$match_choice" ] && [ "$match_choice" != "prefix" ]; then
      args+=(--match "$match_choice")
    fi
    if [ -n "$priority_choice" ] && [ "$priority_choice" != "100" ]; then
      args+=(--priority "$priority_choice")
    fi
    if [ -n "$target_choice" ] && [ "$target_choice" != "none" ]; then
      args+=(--target "$target_choice")
    fi
    if [ -n "$rewrite_choice" ] && [ "$rewrite_choice" != "none" ]; then
      args+=(--rewrite "$rewrite_choice")
    fi
    if [ -n "$reason_choice" ] && [ "$reason_choice" != "-" ]; then
      args+=(--reason "$reason_choice")
    fi
    if [ -n "$loc_choice" ] && [ "$loc_choice" != "auto" ]; then
      args+=(--loc "$loc_choice")
    fi
  fi
  if [[ "$CMD" == "update-path-option" && ${#args[@]} -ge 3 ]]; then
    local new_path="${args[3]:-}" new_listen="${args[4]:-}" ws_choice="${args[5]:-}" redirect_choice="${args[6]:-}" header_choice="${args[7]:-}"
    local match_choice="${args[8]:-}" priority_choice="${args[9]:-}" target_choice="${args[10]:-}"
    local rewrite_choice="${args[11]:-}" reason_choice="${args[12]:-}" loc_choice="${args[13]:-}"
    args=("${args[0]}" "${args[1]}" "${args[2]}")
    [ -n "$new_path" ] && args+=(--new-path "$new_path")
    [ -n "$new_listen" ] && args+=(--nginx-port "$new_listen")
    [ -n "$ws_choice" ] && args+=(--ws "$ws_choice")
    [ -n "$redirect_choice" ] && args+=(--redirect "$redirect_choice")
    [ -n "$header_choice" ] && args+=(--headers "$header_choice")
    [ -n "$match_choice" ] && args+=(--match "$match_choice")
    [ -n "$priority_choice" ] && args+=(--priority "$priority_choice")
    [ -n "$target_choice" ] && args+=(--target "$target_choice")
    [ -n "$rewrite_choice" ] && args+=(--rewrite "$rewrite_choice")
    [ -n "$reason_choice" ] && args+=(--reason "$reason_choice")
    [ -n "$loc_choice" ] && args+=(--loc "$loc_choice")
  fi
  if [[ "$CMD" == "add-port" && ${#args[@]} -ge 6 ]]; then
    local domain="${args[0]:-}" nginx_port="${args[1]:-}" container_port="${args[2]:-}" protocol="${args[3]:-}"
    local cert_path="${args[4]:-}" ws="${args[5]:-}" http3_choice="${args[6]:-}" alt_svc_choice="${args[7]:-}"
    args=("$domain" "$nginx_port" "$container_port" "$protocol" "$cert_path" "$ws")
    if [ "$protocol" = "https" ]; then
      [ -n "$http3_choice" ] && args+=(--http3 "$http3_choice")
      [ -n "$alt_svc_choice" ] && args+=(--alt-svc "$alt_svc_choice")
    fi
  fi
  if { [[ "$CMD" == "add-cert" ]] || [[ "$CMD" == "replace-cert" ]]; } && [ ${#args[@]} -ge 3 ]; then
    local cert_domain="${args[0]:-}" cert_port="${args[1]:-443}" cert_choice="${args[2]:-selfsigned}"
    local upload_fullchain="${args[3]:-}" upload_privkey="${args[4]:-}"
    [ -n "$cert_port" ] || cert_port="443"
    [ -n "$cert_choice" ] || cert_choice="selfsigned"
    args=("$cert_domain" "$cert_port" "$cert_choice")
    if [ "$cert_choice" = "upload" ]; then
      args+=("$upload_fullchain" "$upload_privkey")
    fi
  fi
  if [[ "$CMD" == "remove-all-path-options" && ${#args[@]} -ge 1 ]]; then
    if [ "${args[0]}" = "__ALL__" ]; then
      args=()
    fi
  fi
  if [[ "$CMD" == "uninstall-all" && ${#args[@]} -ge 1 ]]; then
    local selected_scope="${args[0]:-backend}"
    [ -n "$selected_scope" ] || selected_scope="backend"
    args=(--scope "$selected_scope")
  fi
  if [[ "$CMD" == "fix-permissions" && ${#args[@]} -ge 1 ]]; then
    if [ "${args[0]}" = "__DEFAULT__" ]; then
      args=()
    fi
  fi
  if [[ "$CMD" == "upgrade-preflight" && ${#args[@]} -ge 2 ]]; then
    local target_tag="${args[0]:-}" require_backup="${args[1]:-no}"
    args=()
    if [ "$require_backup" = "yes" ]; then
      args+=(--require-backup)
    fi
    if [ -n "$target_tag" ]; then
      args+=("$target_tag")
    fi
  fi
  if [[ "$CMD" == "start-nginx" ]]; then
    if [ ${#args[@]} -gt 0 ]; then
      local img="${args[0]:-}" opts="${args[1]:-}"
      args=()
      if [ -n "$img" ] && [ "$img" != "__DEFAULT__" ] && [ "$img" != "$NGINX_IMAGE" ]; then
        # Interpret a bare tag like "latest" as nginx:<tag> for convenience
        if [[ "$img" != *"/"* && "$img" != *":"* && "$img" != "nginx" ]]; then
          img="nginx:${img}"
        fi
        args+=(--nginx-image "$img")
      fi
      if [ "$opts" = "__NGINX_DOCKER_OPTS_CLEAR__" ]; then
        if [ -n "$NGINX_DOCKER_OPTS" ]; then
          args+=(--docker-opts "")
        fi
      elif [ -n "$opts" ] && [ "$opts" != "$NGINX_DOCKER_OPTS" ]; then
        args+=(--docker-opts "$opts")
      fi
    fi
  fi
  if [[ "$CMD" == "set-nginx-docker-opts" && ${#args[@]} -ge 1 ]]; then
    if [ "${args[0]}" = "__NGINX_DOCKER_OPTS_CLEAR__" ]; then
      args=("")
    fi
  fi
  if [[ "$CMD" == "set-nginx-image" && ${#args[@]} -ge 1 ]]; then
    local nginx_pull_mode="${args[1]:-}"
    case "${args[0]}" in
    __LATEST_IF_MISSING__)
      args=("nginx:latest" "${nginx_pull_mode:-if-missing}")
      ;;
    __LATEST_ALWAYS__)
      args=("nginx:latest" "${nginx_pull_mode:-always}")
      ;;
    __PINNED_CURRENT__)
      args=("$NGINX_IMAGE" "${nginx_pull_mode:-${NGINX_PULL_MODE:-if-missing}}")
      ;;
    __MANUAL__) ;;
    esac
  fi
  if [[ "$CMD" == "set-certbot-image" && ${#args[@]} -ge 1 ]]; then
    local certbot_pull_mode="${args[1]:-}"
    case "${args[0]}" in
    __LATEST_IF_MISSING__)
      args=("certbot/certbot:latest" "${certbot_pull_mode:-if-missing}")
      ;;
    __LATEST_ALWAYS__)
      args=("certbot/certbot:latest" "${certbot_pull_mode:-always}")
      ;;
    __PINNED_CURRENT__)
      args=("$CERTBOT_IMAGE" "${certbot_pull_mode:-${CERTBOT_PULL_MODE:-if-missing}}")
      ;;
    __MANUAL__) ;;
    esac
  fi

  if [ "${#args[@]}" -gt 0 ]; then
    PROMPT_ARGS_COLLECTED=("${args[@]}")
  else
    PROMPT_ARGS_COLLECTED=()
  fi
}
