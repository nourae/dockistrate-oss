# shellcheck shell=bash

# Draft discovery must not prepare the runtime or validate editable files: an
# unfinished draft still needs to be selectable for validation and repair.
function __arg_choices_domain_config_target() {
  local domain="" status=""
  printf '%s\n' '--all|All domains'
  if declare -F domain_config_list >/dev/null 2>&1; then
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      status=""
      if declare -F domain_config_status >/dev/null 2>&1; then
        status="$(domain_config_status "$domain" 2>/dev/null)" || status="invalid draft"
      fi
      if [ -n "$status" ]; then
        printf '%s|%s (%s)\n' "$domain" "$domain" "$status"
      else
        printf '%s\n' "$domain"
      fi
    done < <(domain_config_list all)
  fi
  printf '%s\n' '__MANUAL__|Enter a domain manually...'
}

function __arg_choices_domain_config_kind() {
  printf '%s\n' \
    'backend|Backend with its own container' \
    'alias|Alias for an existing backend' \
    'dedicated|Dedicated hostname with independent settings' \
    'certificate-only|Certificates without a backend container'
}

function __arg_choices_domain_config_action() {
  printf '%s\n' \
    'preview|Review changes without applying them' \
    'apply|Apply changes'
}
