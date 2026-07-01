#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-menu-categories.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

function assert_array_values() {
  local array_name="$1"
  shift
  local expected=("$@")
  local actual=()
  local idx

  if ! [[ "$array_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "[Error] Invalid array name '${array_name}'." >&2
    exit 1
  fi
  if ! eval "declare -p ${array_name}" >/dev/null 2>&1; then
    echo "[Error] Missing expected array: ${array_name}." >&2
    exit 1
  fi
  eval "actual=(\"\${${array_name}[@]}\")"
  if [ "${#actual[@]}" -ne "${#expected[@]}" ]; then
    echo "[Error] ${array_name} length mismatch: expected ${#expected[@]}, got ${#actual[@]}." >&2
    printf '[Error] Actual values: %s\n' "${actual[*]}" >&2
    exit 1
  fi

  for idx in "${!expected[@]}"; do
    if [ "${actual[$idx]}" != "${expected[$idx]}" ]; then
      echo "[Error] ${array_name} item ${idx} mismatch: expected '${expected[$idx]}', got '${actual[$idx]}'." >&2
      exit 1
    fi
  done
}

if declare -p INTERACTIVE_PICKER_COMMANDS_BACKENDS_PORTS >/dev/null 2>&1; then
  echo "[Error] Backends & Ports should no longer be a single oversized interactive command group." >&2
  exit 1
fi
if declare -p INTERACTIVE_PICKER_COMMANDS_OVERRIDES >/dev/null 2>&1; then
  echo "[Error] Backend Overrides should be split into narrower interactive command groups." >&2
  exit 1
fi
if declare -p INTERACTIVE_PICKER_COMMANDS_GLOBAL_SETTINGS >/dev/null 2>&1; then
  echo "[Error] Global Settings should be split into narrower interactive command groups." >&2
  exit 1
fi

assert_array_values INTERACTIVE_PICKER_CATEGORIES \
  "Basic Ops" "Backends" "Hosts & Aliases" \
  "Routing & Ports" "Advanced Path Routing" \
  "Port TLS & HTTP/3" "Bulk Backend Operations" \
  "Certificates" "Clean & Uninstall" "Backend Headers" "Logging" \
  "Backend Protocol & IP Overrides" "Backend mTLS & Client Certs" "Backend Access Overrides" \
  "Access Control & Rules" \
  "Diagnostics" "Updates" "Backups & Restore" \
  "Global Nginx Directives" "Global Headers & IP" "Global Access Defaults" "Global TLS & Runtime" \
  "Traffic Capture"

assert_array_values INTERACTIVE_PICKER_COMMANDS_BACKENDS \
  list-backends add-backend remove-backend \
  start-backend stop-backend restart-backend update-backend replace-backend-network

assert_array_values INTERACTIVE_PICKER_COMMANDS_HOSTS_ALIASES \
  add-host-alias remove-host-alias list-host-aliases \
  add-dedicated-host remove-dedicated-host list-dedicated-hosts \
  set-dedicated-host-inherit show-dedicated-host-inherit

assert_array_values INTERACTIVE_PICKER_COMMANDS_ROUTING_PORTS \
  add-port remove-port update-port enable-ws disable-ws \
  set-port-redirect remove-port-redirect list-port-mappings

assert_array_values INTERACTIVE_PICKER_COMMANDS_PATH_ROUTING \
  add-path-option update-path-option remove-path-option remove-all-path-options list-path-options

assert_array_values INTERACTIVE_PICKER_COMMANDS_PORT_TLS_HTTP3 \
  set-port-http3 list-port-http3 \
  set-port-tls-protocols remove-port-tls-protocols set-port-tls-ciphers remove-port-tls-ciphers

assert_array_values INTERACTIVE_PICKER_COMMANDS_BULK_BACKENDS \
  start-all-backends stop-all-backends restart-all-backends remove-all-backends

assert_array_values INTERACTIVE_PICKER_COMMANDS_UPDATES \
  help-update upgrade-preflight

assert_array_values INTERACTIVE_PICKER_HOME_COMMANDS_UPDATES \
  help-update upgrade-preflight

assert_array_values INTERACTIVE_PICKER_COMMANDS_BACKEND_PROTOCOL_IP_OVERRIDES \
  set-backend-http-version remove-backend-http-version \
  set-backend-client-ip-header remove-backend-client-ip-header \
  set-backend-proxy-ip-header remove-backend-proxy-ip-header

assert_array_values INTERACTIVE_PICKER_COMMANDS_BACKEND_MTLS_CLIENT_CERTS \
  enable-backend-mtls disable-backend-mtls \
  add-backend-client-cert revoke-backend-client-cert remove-backend-client-cert list-backend-client-certs replace-backend-client-cert export-backend-client-p12 list-backend-cas replace-backend-ca remove-backend-ca

assert_array_values INTERACTIVE_PICKER_COMMANDS_BACKEND_ACCESS_OVERRIDES \
  set-backend-acl-policy remove-backend-acl-policy \
  set-backend-acl-status remove-backend-acl-status \
  set-backend-security-rule-status remove-backend-security-rule-status

assert_array_values INTERACTIVE_PICKER_COMMANDS_BACKUPS_RESTORE \
  create-backup list-backups restore-backup \
  set-auto-backups set-backup-retention set-backup-compression

assert_array_values INTERACTIVE_PICKER_COMMANDS_GLOBAL_NGINX_DIRECTIVES \
  set-nginx-directive set-nginx-directive-raw remove-nginx-directive remove-all-nginx-directives \
  list-nginx-directives list-nginx-directive-catalog set-nginx-directive-strict show-nginx-directive-strict

assert_array_values INTERACTIVE_PICKER_COMMANDS_GLOBAL_HEADERS_IP \
  control-server-tokens show-server-tokens \
  set-client-ip-header set-proxy-ip-header \
  add-header update-header remove-header list-headers \
  set-hsts set-csp \
  set-trusted-proxies set-real-ip-recursive

assert_array_values INTERACTIVE_PICKER_COMMANDS_GLOBAL_ACCESS_DEFAULTS \
  set-security-rule-status set-acl-status set-acl-policy

assert_array_values INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME \
  set-http-version set-tls-protocols set-tls-ciphers \
  set-nginx-docker-opts show-nginx-docker-opts set-visibility-policy show-visibility-policy set-nginx-image set-certbot-image

duplicates_file="${tmp_dir}/duplicates.txt"
awk '
  /^INTERACTIVE_PICKER_COMMANDS_[A-Z0-9_]+=\(/ { in_arr=1; next }
  in_arr && /^\)/ { in_arr=0; next }
  in_arr {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^[a-z][a-z0-9-]*$/) {
        print $i
      }
    }
  }
' "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh" | sort | uniq -d >"$duplicates_file"

if [ -s "$duplicates_file" ]; then
  echo "[Error] Duplicate commands found across interactive picker categories:" >&2
  sed 's/^/  - /' "$duplicates_file" >&2
  exit 1
fi

echo "[tests] interactive_picker_menu_categories_split.sh: PASS"
