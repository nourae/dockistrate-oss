# shellcheck shell=bash

INTERACTIVE_PICKER_HOME_ADD_BACKEND_LABEL="Add a new backend"
INTERACTIVE_PICKER_HOME_RECENTS_LABEL="Recent commands"
INTERACTIVE_PICKER_HOME_FAVORITES_LABEL="Favorites"
INTERACTIVE_PICKER_HOME_PORTS_LABEL="Expose or update a port"
INTERACTIVE_PICKER_HOME_SERVICES_LABEL="Start / stop services"
INTERACTIVE_PICKER_HOME_CERTIFICATES_LABEL="Certificates"
INTERACTIVE_PICKER_HOME_SECURITY_LABEL="Access control & security rules"
INTERACTIVE_PICKER_HOME_UPDATES_LABEL="Updates / release preflight"
INTERACTIVE_PICKER_HOME_DIAGNOSTICS_LABEL="Diagnostics / troubleshoot"
INTERACTIVE_PICKER_HOME_SEARCH_LABEL="Search all commands"
INTERACTIVE_PICKER_HOME_ADVANCED_LABEL="Advanced command browser"

# Home data is consumed by interactive_picker.sh after this file is sourced.
# shellcheck disable=SC2034
INTERACTIVE_PICKER_HOME_OPTIONS=(
  "$INTERACTIVE_PICKER_HOME_ADD_BACKEND_LABEL"
  "$INTERACTIVE_PICKER_HOME_RECENTS_LABEL"
  "$INTERACTIVE_PICKER_HOME_FAVORITES_LABEL"
  "$INTERACTIVE_PICKER_HOME_PORTS_LABEL"
  "$INTERACTIVE_PICKER_HOME_SERVICES_LABEL"
  "$INTERACTIVE_PICKER_HOME_CERTIFICATES_LABEL"
  "$INTERACTIVE_PICKER_HOME_SECURITY_LABEL"
  "$INTERACTIVE_PICKER_HOME_UPDATES_LABEL"
  "$INTERACTIVE_PICKER_HOME_DIAGNOSTICS_LABEL"
  "$INTERACTIVE_PICKER_HOME_SEARCH_LABEL"
  "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL"
)

# shellcheck disable=SC2034
INTERACTIVE_PICKER_HOME_COMMANDS_PORTS=(
  add-port update-port remove-port list-port-mappings
)

# shellcheck disable=SC2034
INTERACTIVE_PICKER_HOME_COMMANDS_SERVICES=(
  start-nginx stop-nginx remove-nginx
  start-backend stop-backend restart-backend
  start-all-backends stop-all-backends restart-all-backends
)

# The home diagnostics task intentionally includes read-only status commands from
# Basic Ops so troubleshooting is reachable without opening the advanced browser.
# shellcheck disable=SC2034
INTERACTIVE_PICKER_HOME_COMMANDS_DIAGNOSTICS=(
  status status-all check-config tail-proxy-logs
)

# shellcheck disable=SC2034
INTERACTIVE_PICKER_HOME_COMMANDS_UPDATES=(
  help-update upgrade-preflight
)

INTERACTIVE_PICKER_CATEGORIES=(
  "Basic Ops" "Backends" "Hosts & Aliases"
  "Routing & Ports" "Advanced Path Routing"
  "Port TLS & HTTP/3" "Bulk Backend Operations"
  "Certificates" "Clean & Uninstall" "Backend Headers" "Logging"
  "Backend Protocol & IP Overrides" "Backend mTLS & Client Certs" "Backend Access Overrides"
  "Access Control & Rules"
  "Diagnostics" "Updates" "Backups & Restore"
  "Global Nginx Directives" "Global Headers & IP" "Global Access Defaults" "Global TLS & Runtime"
  "Traffic Capture"
)

INTERACTIVE_PICKER_COMMANDS_BASIC=(
  start-nginx stop-nginx remove-nginx update-nginx-config status status-all fix-default-config fix-permissions
)

INTERACTIVE_PICKER_COMMANDS_BACKENDS=(
  list-backends add-backend remove-backend
  start-backend stop-backend restart-backend update-backend replace-backend-network
)

INTERACTIVE_PICKER_COMMANDS_HOSTS_ALIASES=(
  add-host-alias remove-host-alias list-host-aliases
  add-dedicated-host remove-dedicated-host list-dedicated-hosts
  set-dedicated-host-inherit show-dedicated-host-inherit
)

INTERACTIVE_PICKER_COMMANDS_ROUTING_PORTS=(
  add-port remove-port update-port enable-ws disable-ws
  set-port-redirect remove-port-redirect list-port-mappings
)

INTERACTIVE_PICKER_COMMANDS_PATH_ROUTING=(
  add-path-option update-path-option remove-path-option remove-all-path-options list-path-options
)

INTERACTIVE_PICKER_COMMANDS_PORT_TLS_HTTP3=(
  set-port-http3 list-port-http3
  set-port-tls-protocols remove-port-tls-protocols set-port-tls-ciphers remove-port-tls-ciphers
)

INTERACTIVE_PICKER_COMMANDS_BULK_BACKENDS=(
  start-all-backends stop-all-backends restart-all-backends remove-all-backends
)

INTERACTIVE_PICKER_COMMANDS_CERTIFICATES=(
  add-cert replace-cert list-certs renew-certs remove-cert
)

INTERACTIVE_PICKER_COMMANDS_CLEAN=(
  clean-all uninstall-all
)

INTERACTIVE_PICKER_COMMANDS_BACKEND_HEADERS=(
  add-backend-header update-backend-header remove-backend-header remove-all-backend-headers list-backend-headers remove-all-headers
  set-backend-hsts set-backend-csp
)

INTERACTIVE_PICKER_COMMANDS_LOGGING=(
  list-log-fields add-log-field remove-log-field update-log-field move-log-field
)

INTERACTIVE_PICKER_COMMANDS_BACKEND_PROTOCOL_IP_OVERRIDES=(
  set-backend-http-version remove-backend-http-version
  set-backend-client-ip-header remove-backend-client-ip-header
  set-backend-proxy-ip-header remove-backend-proxy-ip-header
)

INTERACTIVE_PICKER_COMMANDS_BACKEND_MTLS_CLIENT_CERTS=(
  enable-backend-mtls disable-backend-mtls
  add-backend-client-cert revoke-backend-client-cert remove-backend-client-cert list-backend-client-certs replace-backend-client-cert export-backend-client-p12 list-backend-cas replace-backend-ca remove-backend-ca
)

INTERACTIVE_PICKER_COMMANDS_BACKEND_ACCESS_OVERRIDES=(
  set-backend-acl-policy remove-backend-acl-policy
  set-backend-acl-status remove-backend-acl-status
  set-backend-security-rule-status remove-backend-security-rule-status
)

INTERACTIVE_PICKER_COMMANDS_ACL_RULES=(
  add-acl remove-acl disable-acl enable-acl disable-all-acl enable-all-acl remove-all-acl update-acl move-acl-rule list-acl
  add-security-rule update-security-rule remove-security-rule remove-all-security-rules disable-security-rule enable-security-rule disable-all-security-rules enable-all-security-rules move-security-rule set-security-rule-mode duplicate-security-rule list-security-rules
)

INTERACTIVE_PICKER_COMMANDS_DIAG=(
  check-config tail-proxy-logs
)

INTERACTIVE_PICKER_COMMANDS_UPDATES=(
  help-update upgrade-preflight
)

INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE=(
  create-backup list-backups restore-backup
  set-auto-backups set-backup-retention set-backup-compression
)

INTERACTIVE_PICKER_COMMANDS_GLOBAL_NGINX_DIRECTIVES=(
  set-nginx-directive set-nginx-directive-raw remove-nginx-directive remove-all-nginx-directives
  list-nginx-directives list-nginx-directive-catalog set-nginx-directive-strict show-nginx-directive-strict
)

INTERACTIVE_PICKER_COMMANDS_GLOBAL_HEADERS_IP=(
  control-server-tokens show-server-tokens
  set-client-ip-header set-proxy-ip-header
  add-header update-header remove-header list-headers
  set-hsts set-csp
  set-trusted-proxies set-real-ip-recursive
)

INTERACTIVE_PICKER_COMMANDS_GLOBAL_ACCESS_DEFAULTS=(
  set-security-rule-status set-acl-status set-acl-policy
)

INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME=(
  set-http-version set-tls-protocols set-tls-ciphers
  set-nginx-docker-opts show-nginx-docker-opts set-visibility-policy show-visibility-policy set-nginx-image set-certbot-image
)

INTERACTIVE_PICKER_COMMANDS_CAPTURE=(
  start-capture stop-capture
)

INTERACTIVE_PICKER_CATEGORY_COMMANDS=()
INTERACTIVE_PICKER_FLATTENED_COMMANDS=()
INTERACTIVE_PICKER_FLATTENED_CATEGORIES=()

function interactive_picker_commands_for_category() {
  local category="$1"
  INTERACTIVE_PICKER_CATEGORY_COMMANDS=()

  case "$category" in
  "Basic Ops") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BASIC[@]}") ;;
  "Backends") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BACKENDS[@]}") ;;
  "Hosts & Aliases") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_HOSTS_ALIASES[@]}") ;;
  "Routing & Ports") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_ROUTING_PORTS[@]}") ;;
  "Advanced Path Routing") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_PATH_ROUTING[@]}") ;;
  "Port TLS & HTTP/3") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_PORT_TLS_HTTP3[@]}") ;;
  "Bulk Backend Operations") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BULK_BACKENDS[@]}") ;;
  "Certificates") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_CERTIFICATES[@]}") ;;
  "Clean & Uninstall") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_CLEAN[@]}") ;;
  "Backend Headers") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BACKEND_HEADERS[@]}") ;;
  "Logging") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_LOGGING[@]}") ;;
  "Backend Protocol & IP Overrides") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BACKEND_PROTOCOL_IP_OVERRIDES[@]}") ;;
  "Backend mTLS & Client Certs") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BACKEND_MTLS_CLIENT_CERTS[@]}") ;;
  "Backend Access Overrides") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BACKEND_ACCESS_OVERRIDES[@]}") ;;
  "Access Control & Rules") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_ACL_RULES[@]}") ;;
  "Diagnostics") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_DIAG[@]}") ;;
  "Updates") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_UPDATES[@]}") ;;
  "Backups & Restore") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE[@]}") ;;
  "Global Nginx Directives") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_GLOBAL_NGINX_DIRECTIVES[@]}") ;;
  "Global Headers & IP") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_GLOBAL_HEADERS_IP[@]}") ;;
  "Global Access Defaults") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_GLOBAL_ACCESS_DEFAULTS[@]}") ;;
  "Global TLS & Runtime") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME[@]}") ;;
  "Traffic Capture") INTERACTIVE_PICKER_CATEGORY_COMMANDS=("${INTERACTIVE_PICKER_COMMANDS_CAPTURE[@]}") ;;
  *) return 1 ;;
  esac
}

function interactive_flatten_picker_commands() {
  local seen_commands=$'\n'
  local category command

  INTERACTIVE_PICKER_FLATTENED_COMMANDS=()
  INTERACTIVE_PICKER_FLATTENED_CATEGORIES=()

  for category in "${INTERACTIVE_PICKER_CATEGORIES[@]}"; do
    interactive_picker_commands_for_category "$category" || return 1
    for command in "${INTERACTIVE_PICKER_CATEGORY_COMMANDS[@]}"; do
      case "$seen_commands" in
      *$'\n'"$command"$'\n'*) continue ;;
      esac
      INTERACTIVE_PICKER_FLATTENED_COMMANDS+=("$command")
      INTERACTIVE_PICKER_FLATTENED_CATEGORIES+=("$category")
      seen_commands="${seen_commands}${command}"$'\n'
    done
  done
}
