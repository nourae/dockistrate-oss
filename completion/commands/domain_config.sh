#!/usr/bin/env bash
# Completion provides cur/cword; these generated tokens contain no whitespace.
# Bash 3 has no mapfile for the compgen arrays used throughout completion.
# shellcheck disable=SC2154,SC2207

function __dockistrate_load_domain_config() {
  if ! declare -F domain_config_list >/dev/null 2>&1; then
    local domain_loader=""
    domain_loader="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/domain_config.sh" || return 1
    [ -r "$domain_loader" ] || return 1
    # The loader only declares functions; completion must never bootstrap state.
    # shellcheck source=../../lib/domain_config.sh
    source "$domain_loader" || return 1
    if ! declare -F csv_parse_line >/dev/null 2>&1; then source "${domain_loader%/*}/utils/csv.sh" || return 1; fi
    if ! declare -F csv_read_records >/dev/null 2>&1; then source "${domain_loader%/*}/utils/csv_records.sh" || return 1; fi
  fi
}

function __dockistrate_domain_config_domains() {
  __dockistrate_load_domain_config || return 0
  domain_config_list all 2>/dev/null
}

function __dockistrate_domain_certificate_refs() {
  __dockistrate_load_domain_config || return 0
  declare -F domain_config_active >/dev/null 2>&1 && domain_config_active || return 0
  local root="" owner="" dir="" certificate_id=""
  root="$(domain_config_root)" || return 0
  while IFS= read -r owner; do
    [ ! -L "$root/$owner/certs" ] || continue
    for dir in "$root/$owner/certs/"*; do
      [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/fullchain.pem" ] || continue
      if [ -f "$dir/certificate.csv" ]; then
        local declared=""
        declared="$(_domain_runtime_get "$dir/certificate.csv" declared yes 2>/dev/null)" || continue
        [ "$declared" != no ] || continue
      fi
      certificate_id="${dir##*/}"
      case "$certificate_id" in '' | . | .. | *[!a-zA-Z0-9_.-]*) continue ;; esac
      printf '%s/%s\n' "$owner" "$certificate_id"
    done
  done < <(domain_config_list all)
}

function _dockistrate_complete_domain_config() {
  local command="$1" domains=""
  case "$command" in
  init-domain-config)
    if [ "${prev:-}" = --kind ]; then
      COMPREPLY=($(compgen -W 'backend alias dedicated certificate-only' -- "$cur"))
    elif [ "$cword" -gt 2 ]; then
      COMPREPLY=($(compgen -W '--kind' -- "$cur"))
    else
      COMPREPLY=()
    fi
    return 0
    ;;
  validate-domain-config | apply-domain-config)
    if [ "$cword" -eq 2 ]; then
      domains="$(__dockistrate_domain_config_domains)" || domains=""
      COMPREPLY=($(compgen -W "--all $domains" -- "$cur"))
    elif [ "$command" = apply-domain-config ]; then
      COMPREPLY=($(compgen -W '--dry-run' -- "$cur"))
    else
      COMPREPLY=()
    fi
    return 0
    ;;
  migrate-state | restore-backup)
    if [ "${prev:-}" = --backend-details ]; then
      COMPREPLY=()
      while IFS= read -r domains; do
        COMPREPLY+=("$domains")
      done < <(compgen -f -- "$cur")
      compopt -o filenames 2>/dev/null || true
    elif [ "$command" = migrate-state ]; then
      COMPREPLY=($(compgen -W '--dry-run --backend-details' -- "$cur"))
    elif [ "$cword" -gt 2 ]; then
      COMPREPLY=($(compgen -W '--backend-details' -- "$cur"))
    else
      return 1
    fi
    return 0
    ;;
  esac
  return 1
}

__dockistrate_completion_handlers+=(_dockistrate_complete_domain_config)
