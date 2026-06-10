#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/nginx.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backends.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/tls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/ports.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/headers.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/tests/helpers/stubs.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_p12_fail.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

SKIP_DOCKER_CHECKS=true

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
CERTS_DIR="$STATE_DIR/certs"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
CUSTOM_HEADERS_FILE="$CONFIG_DIR/custom_headers.csv"
BACKEND_HEADERS_FILE="$CONFIG_DIR/backend_headers.csv"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
SECURITY_RULES_FILE="$CONFIG_DIR/security_rules.csv"
SECURITY_IP_RULES_FILE="$CONFIG_DIR/security_ip_rules.csv"
SECURITY_RULES_DB="$SECURITY_RULES_FILE"
SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
ACCESS_LOG_FIELDS_FILE="$CONFIG_DIR/access_log_fields.csv"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"

mkdir -p \
  "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
  "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$PATH_HEADER_DIR" \
  "$CERTS_DIR/mtls/export.test" "$ACME_WEBROOT_DIR"

MTLS_DIR="$CERTS_DIR/mtls/export.test"
P12_FILE="$MTLS_DIR/client1.p12"

cat >"$BACKEND_MTLS_FILE" <<EOF_MTLS
${STATE_BACKEND_MTLS_HEADER}
export.test,${MTLS_DIR}
EOF_MTLS

printf 'dummy-cert\n' >"$MTLS_DIR/client1.crt"
printf 'dummy-key\n' >"$MTLS_DIR/client1.key"
printf 'dummy-ca\n' >"$MTLS_DIR/ca.crt"
printf 'existing-bundle\n' >"$P12_FILE"
chmod 640 "$MTLS_DIR/client1.crt" "$MTLS_DIR/ca.crt"
chmod 600 "$MTLS_DIR/client1.key" "$P12_FILE"

function openssl() {
  if [ "${1:-}" = "pkcs12" ]; then
    return 1
  fi
  command openssl "$@"
}

set +e
output="$(P12_PASSWORD='top-secret' export_backend_client_p12 export.test client1 --password-env P12_PASSWORD 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "[Error] export_backend_client_p12 succeeded unexpectedly." >&2
  exit 1
fi

if [ "$(command cat "$P12_FILE")" != "existing-bundle" ]; then
  echo "[Error] Existing PKCS#12 bundle was modified after export failure." >&2
  exit 1
fi

if [ "$(stat -c '%a' "$P12_FILE" 2>/dev/null || stat -f '%Lp' "$P12_FILE")" != "600" ]; then
  echo "[Error] Existing PKCS#12 bundle mode changed unexpectedly after export failure." >&2
  exit 1
fi

if find "$MTLS_DIR" -maxdepth 1 -name '.client1.p12.tmp.*' | grep -q .; then
  echo "[Error] Temporary PKCS#12 export file was left behind after failure." >&2
  exit 1
fi

if ! grep -Fq 'Failed to generate PKCS#12 bundle' <<<"$output"; then
  echo "[Error] Expected PKCS#12 failure message missing." >&2
  echo "$output" >&2
  exit 1
fi

echo "export_backend_client_p12 failure preserves existing PKCS#12 bundle."
