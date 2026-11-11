# shellcheck shell=bash

# Compile backend rules for each configured serving identity. A host's own
# persisted rules remain additive; security_rules=no disables only inheritance.
function _sr_rule_recipients() {
  validate_backend_aliases_state_for_render || return 1
  _sr_rule_recipients_validated "$@"
}

# Internal enumeration after the caller has validated the complete alias table.
# build_security_rules_inc validates once before traversing all rule rows.
function _sr_rule_recipients_validated() {
  local domain="${1:-}" aliases="" dedicated_hosts="" hostname="" inherit=""
  domain="$(normalize_domain "$domain")"
  if ! is_valid_domain "$domain" || ! domain_exists "$domain"; then
    echo "[Error] Cannot resolve security rule identity '${domain}'." >&2
    return 1
  fi
  printf '%s\n' "$domain"
  # Host-specific rows apply to that host only, never back to the primary.
  backend_exists "$domain" || return 0
  aliases="$(list_domain_aliases "$domain")" || return 1
  dedicated_hosts="$(list_dedicated_hosts_for_backend "$domain")" || return 1
  for hostname in $aliases; do
    printf '%s\n' "$hostname"
  done
  for hostname in $dedicated_hosts; do
    inherit="$(get_dedicated_host_inheritance "$hostname" security_rules)" || return 1
    case "$inherit" in
    yes) printf '%s\n' "$hostname" ;;
    no) ;;
    *) echo "[Error] Invalid security-rule inheritance for '${hostname}'." >&2; return 1 ;;
    esac
  done
}

# Bind applicability to the selected server. Only aliases registered for this
# backend may switch the identity, so an arbitrary Host never disables rules.
# Keep request Host/SNI variables intact for predicates and upstream headers.
function _sr_identity_directives() {
  local default_identity="${1:-}" aliases="${2:-}" hostname="" target="" directives=""
  validate_backend_aliases_state_for_render || return 1
  default_identity="$(normalize_domain "$default_identity")"
  if ! is_valid_domain "$default_identity" || ! domain_exists "$default_identity"; then
    echo "[Error] Cannot resolve serving security identity '${default_identity}'." >&2
    return 1
  fi
  printf -v directives '    set $dockistrate_security_identity "%s";\n' "$default_identity"
  for hostname in $aliases; do
    hostname="$(normalize_domain "$hostname")"
    if ! is_valid_domain "$hostname"; then
      echo "[Error] Invalid security-rule alias '${hostname}'." >&2
      return 1
    fi
    [ "$hostname" != "$default_identity" ] || continue
    target="$(backend_for_alias "$hostname")" || return 1
    if [ "$target" != "$default_identity" ]; then
      echo "[Error] Security-rule alias '${hostname}' is not registered for '${default_identity}'." >&2
      return 1
    fi
    directives+="    if (\$host = ${hostname}) { set \$dockistrate_security_identity \"${hostname}\"; }"$'\n'
  done
  printf '%s' "$directives"
}
