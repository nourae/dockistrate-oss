# shellcheck shell=bash

function set_backend_http_version() {
  local domain="${1:-}"
  local ver="${2:-}"
  if [ -z "$domain" ] || [ -z "$ver" ]; then
    echo "[Usage] set-backend-http-version <domain> <http1.0|http1.1|http2>"
    exit 1
  fi
  domain="$(normalize_domain "$domain")"
  if ! domain_exists "$domain"; then
    echo "[Error] Unknown domain '$domain'" >&2
    exit 1
  fi
  case "$ver" in
  http1.0 | http1.1 | http2) ;;
  *)
    echo "[Usage] set-backend-http-version <domain> <http1.0|http1.1|http2>"
    exit 1
    ;;
  esac
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "set_backend_http_version_${domain}_${ver}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$BACKEND_HTTP_FILE")"
  state_csv_upsert_two_col_value "$BACKEND_HTTP_FILE" "$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$domain" "$ver"
  echo "[Info] Set HTTP version for $domain to $ver"
  create_backup "" "SetBackendHTTPVer_${domain}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
