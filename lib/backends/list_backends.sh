# shellcheck shell=bash
function list_backends() {
  local include_state="${LIST_BACKENDS_INCLUDE_STATE:-false}"
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Info] No backends configured."
    return
  fi
  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    return 1
  fi

  local domains=""
  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
    if [ "$STATE_BP_RECORD_TYPE" = "backend" ]; then
      domains+="${STATE_BP_DOMAIN}"$'\n'
    fi
  done <"$BACKEND_PORTS_FILE"

  if [ -z "$domains" ]; then
    echo "[Info] No backends configured."
    return
  fi

  if [ "$include_state" = "true" ]; then
    printf "%-20s | %-10s | %-20s | %-24s | %-24s | %-15s | %-10s | %-5s | %-15s | %-15s | %-5s | %-9s | %-9s | %s\n" \
      "Domain" "State" "Aliases" "Config Image" "Running Image" "Network" "HTTP Ver" "mTLS" "Client IP" "Proxy IP" "ACL" "ACL St" "Sec St" "Ports"
    echo "----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
  else
    printf "%-20s | %-20s | %-24s | %-24s | %-15s | %-10s | %-5s | %-15s | %-15s | %-5s | %-9s | %-9s | %s\n" \
      "Domain" "Aliases" "Config Image" "Running Image" "Network" "HTTP Ver" "mTLS" "Client IP" "Proxy IP" "ACL" "ACL St" "Sec St" "Ports"
    echo "---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
  fi
  printf '%s' "$domains" | sort -u | while IFS= read -r d || [ -n "$d" ]; do
    [ -n "$d" ] || continue
    local ver cip pip mtls_dir mtls acl aclst secst
    ver="$(get_backend_http_version "$d")"
    cip="$(get_backend_client_ip_header "$d")"
    pip="$(get_backend_proxy_ip_header "$d")"
    [ -n "$cip" ] || cip="off"
    [ -n "$pip" ] || pip="off"
    mtls_dir="$(get_backend_mtls_dir "$d")"
    if [ -n "$mtls_dir" ]; then
      mtls="yes"
    else
      mtls="no"
    fi
    acl="$(get_backend_acl_policy "$d")"
    aclst="$(get_backend_acl_status "$d")"
    secst="$(get_backend_security_rule_status "$d")"
    # Build port summary for this domain
    local ports_summary=""
    line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$line" || return 1
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || return 1
      [ "$STATE_BP_RECORD_TYPE" = "port" ] || continue
      [ "$STATE_BP_DOMAIN" = "$d" ] || continue

      local p proto ws redirect code tag extra
      p="$STATE_BP_LISTEN_PORT"
      proto="$STATE_BP_PROTOCOL"
      ws="$STATE_BP_WS"
      redirect="$STATE_BP_REDIRECT_FLAG"
      code="$STATE_BP_REDIRECT_CODE"
      tag="$p:$proto"
      extra=""

      if [ "$proto" = "http" ]; then
        if [ "$ws" = "yes" ]; then
          extra="ws"
        fi
        if [ "$redirect" = "on" ]; then
          if [ -n "$extra" ]; then
            extra+=","
          fi
          if [ -n "$code" ]; then
            extra+="redir${code}"
          else
            extra+="redir"
          fi
        fi
      elif [ "$proto" = "https" ]; then
        extra="tls"
      elif [ "$proto" = "tcp" ]; then
        extra="tcp"
      fi

      if [ -n "$extra" ]; then
        tag="$p:$extra"
      fi
      if [ -z "$ports_summary" ]; then
        ports_summary="$tag"
      else
        ports_summary+="; $tag"
      fi
    done <"$BACKEND_PORTS_FILE"
    [ -n "$ports_summary" ] || ports_summary="-"

    local aliases
    aliases="$(list_domain_aliases "$d" | xargs)"
    [ -n "$aliases" ] || aliases="-"

    local config_img running_img
    config_img="$(get_backend_image "$d" 2>/dev/null || echo "-")"
    running_img="$(summarize_container_image "backend-$(sanitize_domain_name "$d")" 2>/dev/null || echo "-")"
    local net
    net="$(get_backend_network "$d")"

    if [ "$include_state" = "true" ]; then
      local state cname
      cname="backend-$(sanitize_domain_name "$d")"
      state="$(container_status "$cname")"
      [ -n "$state" ] || state="missing"
      printf "%-20s | %-10s | %-20s | %-24s | %-24s | %-15s | %-10s | %-5s | %-15s | %-15s | %-5s | %-9s | %-9s | %s\n" \
        "$d" "$state" "$aliases" "$config_img" "$running_img" "${net:-$DEFAULT_NETWORK}" "$ver" "$mtls" "$cip" "$pip" "$acl" "$aclst" "$secst" "$ports_summary"
    else
      printf "%-20s | %-20s | %-24s | %-24s | %-15s | %-10s | %-5s | %-15s | %-15s | %-5s | %-9s | %-9s | %s\n" \
        "$d" "$aliases" "$config_img" "$running_img" "${net:-$DEFAULT_NETWORK}" "$ver" "$mtls" "$cip" "$pip" "$acl" "$aclst" "$secst" "$ports_summary"
    fi
  done

  # All protocols shown in unified model
}

# Verify that stored backend IPs still match the running containers.
# If an IP changed (for example after the container was recreated), the
# corresponding entry in $BACKEND_PORTS_FILE is updated and a message is
# printed. This keeps generated Nginx configs in sync with actual container
# addresses.
