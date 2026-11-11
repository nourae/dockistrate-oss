# shellcheck shell=bash

function get_backend_mtls_dir() {
  local domain="${1:-}" mtls_dir="" owner_domain=""
  validate_backend_mtls_state_for_render || return 1
  _mtls_resolve_effective_mapping mtls_dir owner_domain "$domain" || return 1
  printf '%s\n' "$mtls_dir"
}
