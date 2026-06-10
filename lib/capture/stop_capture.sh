# shellcheck shell=bash

function stop_capture() {
  local had_tls_decrypt="false"
  local keylog_file=""
  if capture_tls_keylog_file keylog_file 2>/dev/null; then
    :
  else
    keylog_file=""
  fi

  if docker ps --format '{{.Names}}' | grep -q '^nginx-capture$'; then
    docker stop nginx-capture >/dev/null 2>&1 || true
    remove_container_and_anonymous_volumes nginx-capture >/dev/null 2>&1 || true
    echo "[Info] Packet capture stopped."
  elif docker ps -a --format '{{.Names}}' | grep -q '^nginx-capture$'; then
    remove_container_and_anonymous_volumes nginx-capture >/dev/null 2>&1 || true
    echo "[Info] Packet capture stopped."
  else
    echo "[Info] No capture container found."
  fi

  if capture_tls_decrypt_enabled; then
    had_tls_decrypt="true"
    disable_capture_tls_decrypt "command=stop-capture"
    if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
      recreate_nginx_container "$NGINX_IMAGE"
    fi
  elif capture_tls_decrypt_state_exists; then
    had_tls_decrypt="true"
    disable_capture_tls_decrypt "command=stop-capture"
  fi

  if [ "$had_tls_decrypt" = "true" ]; then
    echo "[Info] TLS decrypt capture mode disabled."
    if [ -n "$keylog_file" ] && [ -f "$keylog_file" ]; then
      local keylog_size="0"
      keylog_size="$(wc -c <"$keylog_file" 2>/dev/null || echo 0)"
      keylog_size="${keylog_size//[[:space:]]/}"
      echo "[Info] TLS key log preserved at: ${keylog_file}"
      if [ "$keylog_size" = "0" ]; then
        echo "[Warn] TLS key log file is empty. Decryption may not work if the active Nginx/OpenSSL build does not emit SSL key logs."
      fi
    fi
  fi

  return 0
}
