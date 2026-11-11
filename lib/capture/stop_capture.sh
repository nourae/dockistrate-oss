# shellcheck shell=bash

function stop_capture() {
  if ! declare -F _capture_with_runtime_lock >/dev/null 2>&1; then
    # shellcheck source=lib/capture/lifecycle.sh
    source "$(dirname "${BASH_SOURCE[0]}")/lifecycle.sh" || return 1
  fi
  _capture_with_runtime_lock _capture_stop_runtime
}

function _capture_stop_runtime() {
  local had_tls_decrypt="false"
  local keylog_file=""
  if capture_tls_keylog_file keylog_file 2>/dev/null; then
    :
  else
    keylog_file=""
  fi

  local removed=false
  _capture_remove_existing removed true || return 1
  if [ "$removed" = true ]; then
    echo "[Info] Packet capture stopped and container removed."
  else
    echo "[Info] No capture container running."
  fi
  if capture_tls_decrypt_enabled; then
    had_tls_decrypt="true"
    disable_capture_tls_decrypt "command=stop-capture" || return 1
    if [ "${SKIP_DOCKER_CHECKS:-}" != "true" ]; then
      recreate_nginx_container "$NGINX_IMAGE" || return 1
    fi
  elif capture_tls_decrypt_state_exists; then
    had_tls_decrypt="true"
    disable_capture_tls_decrypt "command=stop-capture" || return 1
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
