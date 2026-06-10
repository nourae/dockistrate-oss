# shellcheck shell=bash

# Check if a certificate expires within the configured renewal window
function _cert_expiring_soon() {
  local cert_path="${1:-}"
  local window_days="${2:-30}"
  local seconds_left

  if [ ! -f "$cert_path" ]; then
    return 0
  fi

  seconds_left=$((window_days * 86400))
  if openssl x509 -checkend "$seconds_left" -noout -in "$cert_path" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}
