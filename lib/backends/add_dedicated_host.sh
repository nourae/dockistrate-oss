# shellcheck shell=bash
function add_dedicated_host() {
  local hostname="${1:-}" domain="${2:-}"
  local inherit_mtls="${3:-yes}"
  local inherit_acl="${4:-yes}"
  local inherit_security_rules="${5:-yes}"
  local inherit_headers="${6:-yes}"
  local inherit_paths="${7:-yes}"

  if [ -z "$hostname" ] || [ -z "$domain" ]; then
    echo "[Usage] add-dedicated-host <hostname> <domain> [inherit_mtls] [inherit_acl] [inherit_security_rules] [inherit_headers] [inherit_paths]"
    echo "        inherit options: yes/no (default: yes for all)"
    exit 1
  fi

  ensure_valid_or_prompt hostname "$hostname" "hostname" "" is_valid_domain
  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain

  hostname="$(normalize_domain "$hostname")"
  domain="$(normalize_domain "$domain")"

  local target_domain
  target_domain="$(primary_domain_for "$domain")"

  if ! backend_exists "$target_domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  if ! backend_has_httpish_port "$target_domain"; then
    echo "[Error] Target '$target_domain' has no HTTP/HTTPS port mapping. Add an HTTP/HTTPS port before creating dedicated hosts." >&2
    exit 1
  fi
  if backend_exists "$hostname"; then
    echo "[Error] Cannot register dedicated host '$hostname' because it is already a backend domain." >&2
    exit 1
  fi
  if alias_exists "$hostname"; then
    local existing_target
    existing_target="$(backend_for_alias "$hostname")"
    if [ -n "$existing_target" ]; then
      echo "[Error] '$hostname' already exists as an alias pointing to backend '$existing_target'." >&2
    else
      echo "[Error] '$hostname' already exists as an alias." >&2
    fi
    exit 1
  fi
  if dedicated_host_exists "$hostname"; then
    local existing_target
    existing_target="$(backend_for_dedicated_host "$hostname")"
    if [ -n "$existing_target" ]; then
      echo "[Error] Dedicated host '$hostname' already points to backend '$existing_target'." >&2
    else
      echo "[Error] Dedicated host '$hostname' already exists." >&2
    fi
    exit 1
  fi

  # Validate inheritance options
  for opt in "$inherit_mtls" "$inherit_acl" "$inherit_security_rules" "$inherit_headers" "$inherit_paths"; do
    case "$opt" in
      yes|no) ;;
      *)
        echo "[Error] Inheritance options must be 'yes' or 'no', got: $opt" >&2
        exit 1
        ;;
    esac
  done

  local started_txn=false
  if ! transaction_is_active; then
    if ! begin_transaction "add_dedicated_host_${hostname}" "$CONFIG_DIR"; then
      return 1
    fi
    started_txn=true
  fi

  if ! set_dedicated_host_alias "$hostname" "$target_domain"; then
    _rollback_handler
  fi

  # Store inheritance settings
  if ! set_dedicated_host_inheritance "$hostname" "$inherit_mtls" "$inherit_acl" "$inherit_security_rules" "$inherit_headers" "$inherit_paths"; then
    _rollback_handler
  fi

  echo "[Info] Added dedicated host '${hostname}' -> '${target_domain}'."
  echo "[Info] Inheritance: mTLS=$inherit_mtls, ACL=$inherit_acl, security_rules=$inherit_security_rules, headers=$inherit_headers, paths=$inherit_paths"
  log_msg "Added dedicated host ${hostname} -> ${target_domain} (inherit: mtls=$inherit_mtls acl=$inherit_acl sec_rules=$inherit_security_rules headers=$inherit_headers paths=$inherit_paths)"
  create_backup "" "AddDedicatedHost_${hostname}"
  update_nginx_config
  if [ "$started_txn" = true ]; then
    end_transaction_success
  fi
}
