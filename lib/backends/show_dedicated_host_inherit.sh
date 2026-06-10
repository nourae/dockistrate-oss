# shellcheck shell=bash

function show_dedicated_host_inherit() {
  local hostname="${1:-}"

  if [ -z "$hostname" ]; then
    echo "[Usage] show-dedicated-host-inherit <hostname>"
    exit 1
  fi

  hostname="$(normalize_domain "$hostname")"

  if ! dedicated_host_exists "$hostname"; then
    echo "[Error] Dedicated host '$hostname' not found." >&2
    exit 1
  fi

  local target_domain
  target_domain="$(backend_for_dedicated_host "$hostname")"

  echo "Dedicated host: $hostname -> $target_domain"
  echo ""
  echo "Inheritance settings:"
  echo "  mTLS:           $(get_dedicated_host_inheritance "$hostname" "mtls")"
  echo "  ACL:            $(get_dedicated_host_inheritance "$hostname" "acl")"
  echo "  Security Rules: $(get_dedicated_host_inheritance "$hostname" "security_rules")"
  echo "  Headers:        $(get_dedicated_host_inheritance "$hostname" "headers")"
  echo "  Paths:          $(get_dedicated_host_inheritance "$hostname" "paths")"
}
