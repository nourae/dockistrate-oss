#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_config_drift.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"
CONFIG_DIR="$STATE_DIR/config"; BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
mkdir -p "$TEST_WORK/candidate/example.com/config" "$DOMAINS_DIR/example.com/runtime/applied" "$CONFIG_DIR"
config="$TEST_WORK/candidate/example.com/config"
printf 'schema_version,role,target\n5,backend,\n' >"$config/domain.csv"
printf 'image,container_port,network,state\nnginx:alpine,8080,testnet,running\n' >"$config/backend.csv"
cp "$config/"*.csv "$DOMAINS_DIR/example.com/runtime/applied/"
cp "$config/backend.csv" "$DOMAINS_DIR/example.com/runtime/backend.csv"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 172.20.0.3:8080 testnet >>"$BACKEND_PORTS_FILE"
SKIP_DOCKER_CHECKS=false
MOCK_STATUS=absent; MOCK_COLLISION=false; MOCK_REJECT_DOMAIN=""
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function backend_exists() { return 0; }
function ensure_no_nginx_container_conflict() { return 0; }
function nginx_container_is_managed() { return 1; }
function get_backend_docker_opts() { :; }
function _backend_identity_load() { BACKEND_IDENTITY_ID=verified-full-id; }
function _backend_runtime_container_is_absent() { [ "$1" = verified-full-id ]; }
function _backend_cleanup_snapshot() {
  BACKEND_CONTAINER_ID=""
  [ "$MOCK_COLLISION" = false ]
}
function _backend_container_snapshot() {
  [ "$1" != "$MOCK_REJECT_DOMAIN" ] || return 1
  [ "$MOCK_STATUS" != absent ] || return 2
  BACKEND_CONTAINER_ID=verified-full-id; BACKEND_CONTAINER_TOKEN=verified-token
  BACKEND_CONTAINER_IMAGE=nginx:alpine; BACKEND_CONTAINER_STATUS=running
  BACKEND_CONTAINER_NETWORKS='testnet|172.20.0.3'
}
function _backend_snapshot_network_ip() { printf '%s\n' 172.20.0.3; }

domain_config_runtime_preview "$TEST_WORK/candidate" >"$TEST_WORK/preview"
grep -q 'recreate absent backend' "$TEST_WORK/preview" || fail_test 'absent owned backend was not planned for recreation'
MOCK_COLLISION=true
if domain_config_runtime_preview "$TEST_WORK/candidate" >"$TEST_WORK/preview" 2>&1; then fail_test 'preview accepted a canonical-name collision'; fi
MOCK_COLLISION=false; MOCK_STATUS=running
if domain_config_backend_runtime_drift example.com; then fail_test 'matching managed backend reported drift'; fi
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 172.20.0.2:8080 testnet >>"$BACKEND_PORTS_FILE"
domain_config_backend_runtime_drift example.com || fail_test 'changed live address was not detected'
domain_config_runtime_preview "$TEST_WORK/candidate" >"$TEST_WORK/preview"
grep -q 'refresh backend address' "$TEST_WORK/preview" || fail_test 'preview omitted address repair'
printf 'unrelated.example.com\n' >"$TEST_WORK/selected"
DOMAIN_CONFIG_SELECTED_FILE="$TEST_WORK/selected"
domain_config_runtime_preview "$TEST_WORK/candidate" >"$TEST_WORK/preview"
[ ! -s "$TEST_WORK/preview" ] || fail_test 'single-domain preview repaired unrelated backend'
unset DOMAIN_CONFIG_SELECTED_FILE
mkdir -p "$TEST_WORK/candidate/z.example.com"
cp -R "$config" "$TEST_WORK/candidate/z.example.com/config"
MOCK_REJECT_DOMAIN=z.example.com
if domain_config_runtime_preflight "$TEST_WORK/candidate" >"$TEST_WORK/preflight" 2>&1; then fail_test 'preflight accepted a later backend ownership failure'; fi
grep -q 'ownership preflight failed for z.example.com' "$TEST_WORK/preflight" || fail_test 'preflight did not inspect every selected backend'

# Existing proxy publications are allowed; every new transport is checked,
# including HTTP/3 UDP alongside the already-owned HTTPS TCP port.
MOCK_REJECT_DOMAIN=""; NGINX_CONTAINER_NAME=proxy; MOCK_PORT_CONFLICT=53/udp
function nginx_container_is_managed() { return 0; }
function container_running() { return 0; }
function container_published_port_bindings() { printf '443/tcp\n'; }
function assert_host_port_available_or_fail() {
  [ "${5:-}" = true ] || fail_test 'Host preflight trusted a stale state mapping'
  printf '%s/%s\n' "$1" "$2" >>"$TEST_WORK/checked-bindings"
  [ "$1/$2" != "$MOCK_PORT_CONFLICT" ]
}
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n443,8080,https,example.com,certificate,no,off,,on,auto\n' >"$config/ports.csv"
printf 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc\n53,8080,udp,,,no,off,,off,auto\n' >"$TEST_WORK/candidate/z.example.com/config/ports.csv"
if domain_config_runtime_preflight "$TEST_WORK/candidate"; then fail_test 'Preflight ignored a new UDP host-port collision'; fi
grep -qx '443/udp' "$TEST_WORK/checked-bindings" || fail_test 'HTTP/3 UDP binding was not preflighted'
if grep -qx '443/tcp' "$TEST_WORK/checked-bindings"; then fail_test 'Preflight rejected a publication owned by the current proxy'; fi
MOCK_PORT_CONFLICT=""
domain_config_runtime_preflight "$TEST_WORK/candidate"

# A restarted old container can receive a different IP during rollback.
source "$ROOT_DIR/lib/backends/update_backend.sh"
MOCK_REJECT_DOMAIN=""
mkdir -p "$TEST_WORK/journal/operations"
_domain_runtime_put "$TEST_WORK/journal/operations/00000001.csv" mode state
_domain_runtime_put "$TEST_WORK/journal/operations/00000001.csv" domain example.com
_domain_runtime_put "$TEST_WORK/journal/operations/00000001.csv" ready yes
function domain_config_record_observed_backend() { :; }
function update_nginx_config() {
  [ "$SKIP_DOCKER_CHECKS" = true ] && [ "$DOMAIN_CONFIG_DEFER_RENDER" = false ] || fail_test 'Rollback tried to alter Docker while regenerating routes'
  cp "$BACKEND_PORTS_FILE" "$TEST_WORK/rendered-routes"
}
function _domain_config_publish_generated() { :; }
_domain_runtime_refresh_recovered_routes "$TEST_WORK/journal"
grep -q '172.20.0.3:8080' "$TEST_WORK/rendered-routes" || fail_test 'Proxy rollback kept the previous backend address'

# An immediate CLI image change keeps the accepted stopped lifecycle when no
# manual apply state override was supplied.
SKIP_DOCKER_CHECKS=true DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_DEFER_RENDER=false INTERACTIVE=false
DEFAULT_NETWORK=testnet
_domain_runtime_put "$DOMAINS_DIR/example.com/runtime/backend.csv" state stopped
function resolve_backend_domain() { printf -v "$1" '%s' "$2"; }
function set_backend_docker_opts() { :; }
function begin_transaction() { TRANSACTION_DEPTH=1; }
function end_transaction_success() { TRANSACTION_DEPTH=0; }
function rollback_pre_hook_remove() { :; }
function _backend_runtime_clear_signal_traps() { :; }
function log_msg() { :; }
function update_nginx_config() { :; }
function _rollback_handler() { fail_test 'Stopped replacement unexpectedly failed'; }
update_backend example.com --image httpd:latest
[ "$(_domain_runtime_get "$DOMAINS_DIR/example.com/runtime/backend.csv" state)" = stopped ] || fail_test 'CLI image replacement changed stopped state to running'
printf '[PASS] domain runtime drift and recreation preview\n'
