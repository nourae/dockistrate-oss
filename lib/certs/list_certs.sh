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
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    _list_domain_certs
    return
  fi
  local found=false
  echo "[Info] Listing certificates:"
  printf "%-12s | %-20s | %-15s | %-7s | %-19s | %-19s | %-6s\n" "Folder" "Domain" "Type" "Ports" "Created" "Expires" "InUse"
  echo "------------------------------------------------------------------------------------------------------------"
  for t in letsencrypt selfsigned custom; do
    [ -d "$CERTS_DIR/$t/live" ] || continue
    for cert_dir in "$CERTS_DIR/$t/live"/*; do
      [ -d "$cert_dir" ] || continue
      found=true
      local folder_name="${cert_dir##*/}"
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
          case " ${ports[*]} " in
          *" $pm_port "*) ;;
          *) ports+=("$pm_port") ;;
          esac
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

function _list_domain_certs() {
  local dir="" owner="" cert_id="" provider="" suffix="" expires="" expiry_line="" created="" kind="" in_use="" port="" ports_str="" declaration="" found=false
  local ports=()
  echo '[Info] Listing certificates:'
  printf '%-32s | %-20s | %-15s | %-7s | %-19s | %-19s | %-6s | %s\n' 'Reference' 'Domain' 'Type' 'Ports' 'Created' 'Expires' 'InUse' 'State'
  while IFS= read -r dir; do
    domain_config_cert_ref_split owner cert_id "$dir" || continue
    provider="$(_domain_runtime_get "$dir/certificate.csv" provider custom)" || return 1
    suffix="$(_domain_runtime_get "$dir/certificate.csv" port_suffix 443)" || return 1
    declaration=declared
    if [ "$(_domain_runtime_get "$dir/certificate.csv" declared yes)" = no ]; then declaration=retained; fi
    expires=''
    if expiry_line="$(openssl x509 -in "$dir/fullchain.pem" -noout -enddate 2>/dev/null)"; then
      expires="${expiry_line#notAfter=}"
    fi
    created="$(cert_created_timestamp "$dir/fullchain.pem")"
    case "$provider" in
    letsencrypt) kind="Let's Encrypt" ;;
    selfsigned) kind='Self-Signed' ;;
    *) kind=Custom ;;
    esac
    ports=("$suffix")
    in_use=No
    while IFS= read -r port; do
      [ -n "$port" ] || continue
      in_use=Yes
      case " ${ports[*]} " in
      *" $port "*) ;;
      *) ports+=("$port") ;;
      esac
    done < <(_list_certs_collect_ports_for_refs "$owner/$cert_id" "$dir")
    ports_str="$(IFS=,; printf '%s' "${ports[*]}")"
    printf '%-32s | %-20s | %-15s | %-7s | %-19s | %-19s | %-6s | %s\n' \
      "$owner/$cert_id" "$owner" "$kind" "$ports_str" "$created" "$expires" "$in_use" "$declaration"
    found=true
  done < <(domain_config_certificate_dirs all)
  if [ "$found" = false ]; then echo '[Info] No certificates found.'; fi
}
