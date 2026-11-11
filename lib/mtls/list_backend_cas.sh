# shellcheck shell=bash

function list_backend_cas() {
  if [ ! -f "$BACKEND_MTLS_FILE" ] || [ ! -s "$BACKEND_MTLS_FILE" ]; then
    echo "[Info] No backend CAs configured"
    return
  fi
  if ! csv_require_header "$BACKEND_MTLS_FILE" "$STATE_BACKEND_MTLS_HEADER"; then
    return 1
  fi
  printf "%-30s | %-40s | %-19s\n" "Domain" "Path" "Expires"
  echo "--------------------------------------------------------------------------------"
  local line="" line_no=0 had_invalid=false
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    if ! csv_parse_line "$line" || [ "$CSV_FIELD_COUNT" -ne "$STATE_BACKEND_MTLS_COLS" ]; then
      printf "%-30s | %-40s | %-19s\n" "[invalid row ${line_no}]" "[invalid mTLS path]" "invalid"
      had_invalid=true
      continue
    fi
    local domain dir normalized_domain normalized_dir
    domain="${CSV_FIELDS[0]}"
    dir="${CSV_FIELDS[1]}"
    normalized_domain="$(normalize_domain "$domain")"
    if [ -z "$domain" ] || [ "$domain" != "$normalized_domain" ] || ! is_valid_domain "$domain"; then
      printf "%-30s | %-40s | %-19s\n" "[invalid domain ${line_no}]" "[invalid mTLS path]" "invalid"
      had_invalid=true
      continue
    fi
    if [ -z "$dir" ] || ! _mtls_validate_owned_dir normalized_dir "$domain" "$dir" >/dev/null 2>&1; then
      printf "%-30s | %-40s | %-19s\n" "$domain" "[invalid mTLS path]" "invalid"
      had_invalid=true
      continue
    fi
    local exp="missing"
    if [ -f "${normalized_dir}/ca.crt" ]; then
      exp=$(openssl x509 -in "${normalized_dir}/ca.crt" -noout -enddate 2>/dev/null | cut -d= -f2)
    fi
    printf "%-30s | %-40s | %-19s\n" "$domain" "$normalized_dir" "$exp"
  done <"$BACKEND_MTLS_FILE"
  [ "$had_invalid" = false ]
}

# Replace the CA for a backend and remove existing client certificates
