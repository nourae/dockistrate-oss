# shellcheck shell=bash

function _list_certs_collect_ports_for_refs() {
  local rel_cert_path="${1:-}" prefixed_cert_path="${2:-}"
  [ -f "$BACKEND_PORTS_FILE" ] || return 0

  local line="" line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! state_backend_ports_parse_line "$line"; then
      continue
    fi
    if [ "$STATE_BP_RECORD_TYPE" = "port" ] &&
      { [ "$STATE_BP_CERT_REF" = "$rel_cert_path" ] || [ "$STATE_BP_CERT_REF" = "$prefixed_cert_path" ]; }; then
      printf '%s\n' "$STATE_BP_LISTEN_PORT"
    fi
  done <"$BACKEND_PORTS_FILE"
}

# New list_certs function
function list_certs() {
  local found=false
  echo "[Info] Listing certificates:"
  printf "%-12s | %-20s | %-15s | %-7s | %-19s | %-19s | %-6s\n" "Folder" "Domain" "Type" "Ports" "Created" "Expires" "InUse"
  echo "------------------------------------------------------------------------------------------------------------"
  for t in letsencrypt selfsigned custom; do
    [ -d "$CERTS_DIR/$t/live" ] || continue
    for cert_dir in "$CERTS_DIR/$t/live"/*; do
      [ -d "$cert_dir" ] || continue
      found=true
      local folder_name="$(basename "$cert_dir")"
      local domain_part
      local port_part
      if [[ "$folder_name" == *_* ]]; then
        domain_part="${folder_name%%_*}"
        port_part="${folder_name##*_}"
      else
        domain_part="$folder_name"
        port_part="443"
      fi
      local fullchain="$cert_dir/fullchain.pem"
      [ -f "$fullchain" ] || continue
      local expires created cert_type in_use
      local issuer subject
      issuer=$(openssl x509 -in "$fullchain" -noout -issuer 2>/dev/null)
      subject=$(openssl x509 -in "$fullchain" -noout -subject 2>/dev/null)
      expires=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2)
      created=$(cert_created_timestamp "$fullchain")
      case "$t" in
      letsencrypt) cert_type="Let's Encrypt" ;;
      selfsigned) cert_type="Self-Signed" ;;
      custom) cert_type="Custom" ;;
      *) cert_type="Other" ;;
      esac
      local rel_cert_path="${t}/live/${folder_name}"
      local prefixed_cert_path="certs/${rel_cert_path}"

      in_use="No"
      if [ -f "${NGINX_HTTP_CONF_DIR}/backends.conf" ] &&
        grep -Fq -- "/${folder_name}/" "${NGINX_HTTP_CONF_DIR}/backends.conf"; then
        in_use="Yes"
      fi

      local ports=("$port_part")
      if [ -f "$BACKEND_PORTS_FILE" ]; then
        while read -r pm_port; do
          if [[ ! " ${ports[*]} " =~ " $pm_port " ]]; then
            ports+=("$pm_port")
          fi
        done < <(_list_certs_collect_ports_for_refs "$rel_cert_path" "$prefixed_cert_path")
      fi
      local ports_str
      ports_str=$(
        IFS=','
        echo "${ports[*]}"
      )

      printf "%-12s | %-20s | %-15s | %-7s | %-19s | %-19s | %-6s\n" "$folder_name" "$domain_part" "$cert_type" "$ports_str" "$created" "$expires" "$in_use"
    done
  done
  if [ "$found" = false ]; then
    echo "[Info] No certificates found."
  fi
}
