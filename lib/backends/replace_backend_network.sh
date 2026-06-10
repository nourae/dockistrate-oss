# shellcheck shell=bash
function replace_backend_network() {
  local domain="${1:-}" net="${2:-}"
  [ -n "$domain" ] && [ -n "$net" ] || {
    echo "[Usage] replace-backend-network <domain> <network>"
    exit 1
  }
  update_backend "$domain" --network "$net"
}

# Start all configured backend containers (HTTP and TCP)
