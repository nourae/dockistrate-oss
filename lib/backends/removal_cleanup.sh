# shellcheck shell=bash

# Resolve only this identity's owned authority, never inherited trust. Disabled
# mTLS has no active mapping, but its canonical material still belongs to it.
function _removed_identity_mtls_target() {
  local output="$1" domain="$2" removed_mtls_path="" candidate=""
  _mtls_get_explicit_owned_dir_for_cleanup removed_mtls_path "$domain" || return 1
  if [ -z "$removed_mtls_path" ]; then
    if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
      domain_config_mtls_dir candidate "$domain" || return 1
    else
      candidate="${CERTS_DIR%/}/mtls/$domain"
    fi
    _mtls_validate_owned_dir_for_cleanup removed_mtls_path "$domain" "$candidate" || return 1
  fi
  printf -v "$output" '%s' "$removed_mtls_path"
}

function _removed_identity_cleanup_artifacts() {
  local domain="$1" mtls_dir="$2" verified="" directory="" name="" generated=""
  # Invalid colliding maps must not erase a surviving identity's artifacts.
  if backend_exists "$domain" || alias_exists "$domain" || dedicated_host_exists "$domain"; then
    return 0
  fi
  # Recheck after transaction start, including material created since preflight.
  if [ -e "$mtls_dir" ] || [ -L "$mtls_dir" ]; then
    _mtls_validate_owned_dir_for_cleanup verified "$domain" "$mtls_dir" || return 1
    _mtls_remove_dir_if_exists "$verified" || return 1
  fi
  name="$(sanitize_domain_name "$domain")"
  for directory in "${SECURITY_IP_DIR:-}" "${SECURITY_IP_STREAM_DIR:-}"; do
    [ -n "$directory" ] || continue
    runtime_state_path_guard_if_declared "$directory/$name.inc" "removed identity ACL include" || return 1
    safe_rm_f "$directory/$name.inc" "$directory" || return 1
  done
  if declare -F domain_config_certificate_layout >/dev/null 2>&1 && domain_config_certificate_layout; then
    generated="${DOMAINS_DIR:-${STATE_DIR}/domains}/$domain/generated/nginx"
    for name in acl-http.inc acl-stream.inc; do
      if [ -e "$generated/$name" ] || [ -L "$generated/$name" ]; then
        runtime_state_path_guard_if_declared "$generated/$name" "removed identity ACL mirror" || return 1
        safe_rm_f "$generated/$name" "$generated" || return 1
      fi
    done
  fi
}
