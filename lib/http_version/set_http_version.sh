# shellcheck shell=bash

function set_http_version() {
  local ver="${1:-}"
  case "$ver" in
  http1.0 | http1.1 | http2) ;;
  *)
    echo "[Usage] set-http-version <http1.0|http1.1|http2>" >&2
    return 1
    ;;
  esac
  begin_transaction_return "set_http_version" "$CONFIG_DIR" || return 1
  HTTP_VERSION="$ver"
  save_config || { transaction_return_failure; return 1; }
  echo "[Info] HTTP version set to $ver"
  update_nginx_config || { transaction_return_failure; return 1; }
  end_transaction_success || { transaction_return_failure; return 1; }
}

# Return custom HTTP version for a backend if set, otherwise the global value
