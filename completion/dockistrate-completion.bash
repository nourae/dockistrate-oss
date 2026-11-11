#!/usr/bin/env bash

__dockistrate_completion_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__dockistrate_commands_dir="${__dockistrate_completion_dir}/commands"
__dockistrate_completion_handlers=()

if [ -d "$__dockistrate_commands_dir" ]; then
  if [ -f "$__dockistrate_commands_dir/common.sh" ]; then
    # Shared helpers for per-command completion scripts.
    . "$__dockistrate_commands_dir/common.sh"
  fi

  for __dockistrate_command_completion in "$__dockistrate_commands_dir"/*.sh; do
    [ -f "$__dockistrate_command_completion" ] || continue
    case "$__dockistrate_command_completion" in
      */common.sh)
        continue
        ;;
    esac
    . "$__dockistrate_command_completion"
  done
fi

_dockistrate_complete() {
  local cur="" prev="" cword=0
  local -a words=()
  COMPREPLY=()
  if declare -F _get_comp_words_by_ref >/dev/null 2>&1; then
    _get_comp_words_by_ref -n =: cur prev words cword
  else
    __dockistrate_native_completion_context
  fi

  # Read only the invoked checkout's generated/applied state. Never source the
  # runtime bootstrap, evaluate saved settings, or change the caller's globals.
  local completion_root="${__dockistrate_completion_dir%/completion}" command_path="${words[0]:-}"
  case "$command_path" in
  */*)
    if [ -f "$command_path" ]; then
      completion_root="$(cd "$(dirname "$command_path")" && pwd)" || return 0
    fi
    ;;
  esac
  local STATE_DIR="$completion_root/state" CONFIG_DIR="$completion_root/state/config"
  local BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv" BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
  local BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv" BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
  local BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv" BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
  local BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv" BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
  local BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"

  local commands="init-domain-config validate-domain-config apply-domain-config migrate-state start-nginx stop-nginx remove-nginx status status-all list-backends fix-default-config update-nginx-config add-backend remove-backend add-host-alias remove-host-alias list-host-aliases add-dedicated-host remove-dedicated-host list-dedicated-hosts set-dedicated-host-inherit show-dedicated-host-inherit start-backend stop-backend restart-backend update-backend replace-backend-network start-all-backends stop-all-backends restart-all-backends remove-all-backends add-cert replace-cert list-certs renew-certs remove-cert add-port remove-port update-port set-port-http3 list-port-http3 set-port-redirect remove-port-redirect add-path-option update-path-option remove-path-option remove-all-path-options list-path-options list-port-mappings enable-ws disable-ws clean-all uninstall-all set-nginx-directive set-nginx-directive-raw remove-nginx-directive remove-all-nginx-directives list-nginx-directives list-nginx-directive-catalog set-nginx-directive-strict show-nginx-directive-strict control-server-tokens show-server-tokens set-client-ip-header set-backend-client-ip-header remove-backend-client-ip-header set-proxy-ip-header set-backend-proxy-ip-header remove-backend-proxy-ip-header add-header update-header remove-header list-headers remove-all-headers add-backend-header update-backend-header remove-backend-header remove-all-backend-headers list-backend-headers set-hsts set-backend-hsts set-csp set-backend-csp list-log-fields add-log-field remove-log-field update-log-field move-log-field set-backend-http-version remove-backend-http-version set-port-tls-protocols remove-port-tls-protocols set-port-tls-ciphers remove-port-tls-ciphers enable-backend-mtls disable-backend-mtls add-backend-client-cert revoke-backend-client-cert remove-backend-client-cert list-backend-client-certs replace-backend-client-cert export-backend-client-p12 list-backend-cas replace-backend-ca remove-backend-ca set-backend-acl-policy remove-backend-acl-policy set-backend-acl-status remove-backend-acl-status set-backend-security-rule-status remove-backend-security-rule-status add-acl remove-acl disable-acl enable-acl remove-all-acl disable-all-acl enable-all-acl update-acl move-acl-rule list-acl add-security-rule fix-permissions remove-security-rule remove-all-security-rules disable-security-rule enable-security-rule disable-all-security-rules enable-all-security-rules update-security-rule set-security-rule-mode move-security-rule list-security-rules duplicate-security-rule check-config tail-proxy-logs help help-update upgrade-preflight create-backup list-backups restore-backup set-auto-backups set-backup-retention set-backup-compression set-http-version set-tls-protocols set-tls-ciphers set-security-rule-status set-acl-status set-acl-policy set-trusted-proxies set-real-ip-recursive set-nginx-docker-opts show-nginx-docker-opts set-visibility-policy show-visibility-policy set-nginx-image set-certbot-image start-capture stop-capture"

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return
  fi

  local command=${words[1]}

  if [[ "$command" == update-backend && "$cword" -gt 2 ]]; then
    case "$prev" in
    --image | --container-port | --docker-opts | --network | --replace-unmanaged-container)
      # In particular, never infer or suggest the replacement container ID.
      COMPREPLY=()
      return
      ;;
    esac
    if [[ "$cur" == --* || -z "$cur" ]]; then
      COMPREPLY=( $(compgen -W "--image --container-port --docker-opts --network --replace-unmanaged-container" -- "$cur") )
      return
    fi
  fi

  local handler
  for handler in "${__dockistrate_completion_handlers[@]}"; do
    if "$handler" "$command"; then
      __dockistrate_trim_wordbreak_reply "$cur"
      return
    fi
  done
}

complete -F _dockistrate_complete dockistrate.sh
