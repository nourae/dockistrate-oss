# shellcheck shell=bash

function __arg_choices_domain_certificates_active() {
  declare -F domain_config_certificate_layout >/dev/null 2>&1 &&
    declare -F domain_config_certificate_dirs >/dev/null 2>&1 &&
    domain_config_certificate_layout
}

function __arg_choices_domain_certificate_owners() {
  local dir="" owner="" cert_id=""
  while IFS= read -r dir; do
    domain_config_cert_ref_split owner cert_id "$dir" || continue
    printf '%s\n' "$owner"
  done < <(domain_config_certificate_dirs all)
}

function __arg_choices_domain_certificate_suffixes() {
  local wanted_domain="${1:-}" dir="" owner="" cert_id="" suffix=""
  while IFS= read -r dir; do
    domain_config_cert_ref_split owner cert_id "$dir" || continue
    [ "$owner" = "$wanted_domain" ] || continue
    suffix="$(_domain_runtime_get "$dir/certificate.csv" port_suffix 443)" || continue
    [ -n "$suffix" ] && printf '%s\n' "$suffix"
  done < <(domain_config_certificate_dirs all)
}

function __arg_choices_domain_certificate_ports() {
  local wanted_owner="${1:-}" wanted_id="${2:-}" line="" line_no=0 mapped_owner="" mapped_id=""
  [ -f "${BACKEND_PORTS_FILE:-}" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    state_backend_ports_parse_line "$line" || continue
    [ "${STATE_BP_RECORD_TYPE:-}" = port ] || continue
    domain_config_cert_ref_split mapped_owner mapped_id "${STATE_BP_CERT_REF:-}" || continue
    if [ "$mapped_owner" = "$wanted_owner" ] && [ "$mapped_id" = "$wanted_id" ]; then
      printf '%s\n' "$STATE_BP_LISTEN_PORT"
    fi
  done <"$BACKEND_PORTS_FILE"
}

function __arg_choices_domain_certificate_paths() {
  local dir="" owner="" cert_id="" provider="" suffix="" fullchain=""
  local expires="" enddate_line="" created="" cert_type="" in_use="" port="" ports_str=""
  local ports=()
  while IFS= read -r dir; do
    domain_config_cert_ref_split owner cert_id "$dir" || continue
    fullchain="$dir/fullchain.pem"
    [ -f "$fullchain" ] || continue
    provider="$(_domain_runtime_get "$dir/certificate.csv" provider custom)" || continue
    suffix="$(_domain_runtime_get "$dir/certificate.csv" port_suffix 443)" || continue
    expires=""
    if enddate_line="$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null)"; then
      expires="${enddate_line#notAfter=}"
    fi
    created="$(__arg_choices_file_mtime_ymd "$fullchain")"
    case "$provider" in
    letsencrypt) cert_type="Let's Encrypt" ;;
    selfsigned) cert_type="Self-Signed" ;;
    *) cert_type="Custom" ;;
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
    done < <(__arg_choices_domain_certificate_ports "$owner" "$cert_id")
    ports_str="$(IFS=,; printf '%s' "${ports[*]}")"
    printf '%s/%s|%s | %s | %s | %s | %s | %s | %s\n' \
      "$owner" "$cert_id" "$cert_id" "$owner" "$cert_type" "$ports_str" "$created" "$expires" "$in_use"
  done < <(domain_config_certificate_dirs)
}
