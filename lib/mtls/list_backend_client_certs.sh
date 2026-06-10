# shellcheck shell=bash

function list_backend_client_certs() {
  local domain="${1:-}" # input-validation-audit: ignore
  if [ -z "$domain" ]; then
    echo "[Usage] list-backend-client-certs <domain>"
    exit 1
  fi
  # Domain and persisted mTLS directory are both revalidated before any state mutation.
  _mtls_normalize_valid_domain domain "$domain" || exit 1
  local mtls_dir
  mtls_dir="$(get_backend_mtls_dir "$domain")"
  [ -n "$mtls_dir" ] || {
    echo "[Info] mTLS not enabled for $domain"
    return
  }
  normalize_mtls_dir mtls_dir "$mtls_dir" || exit 1
  if ! _init_backend_mtls_state "$mtls_dir"; then
    echo "[Error] Failed to initialize mTLS state for $domain" >&2
    return 1
  fi
  local index_file="${mtls_dir}/index.txt"
  local any=false
  for crt in "$mtls_dir"/*.crt; do
    [ -e "$crt" ] || continue
    local base="$(basename "$crt")"
    [ "$base" = "ca.crt" ] && continue
    local cn="${base%.crt}" status="unknown"
    if [ -f "$index_file" ]; then
      status=$(awk -F'\t' -v cn="/CN=${cn}" '$6==cn{print $1; exit}' "$index_file")
      case "$status" in
      V) status="valid" ;;
      R) status="revoked" ;;
      E) status="expired" ;;
      *) status="unknown" ;;
      esac
    fi
    printf "%s (%s)\n" "$cn" "$status"
    any=true
  done
  if [ "$any" = false ]; then
    echo "[Info] No client certificates found for $domain"
  fi
}

# List CAs for backends with mTLS enabled
