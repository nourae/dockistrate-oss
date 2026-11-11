#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backends/common.sh
source "$ROOT_DIR/lib/backends/common.sh"
# shellcheck source=../lib/backends/runtime_rollback.sh
source "$ROOT_DIR/lib/backends/runtime_rollback.sh"
# shellcheck source=../lib/backends/identity.sh
source "$ROOT_DIR/lib/backends/identity.sh"
# shellcheck source=../lib/domain_config.sh
source "$ROOT_DIR/lib/domain_config.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backend_refresh_header.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

STATE_BACKEND_PORTS_HEADER="record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location"
STATE_DIR="$tmp_dir/state"
CONFIG_DIR="$STATE_DIR/config"
DOMAINS_DIR="$STATE_DIR/domains"
DOMAIN_CONFIG_ACTIVE=true
mkdir -p "$CONFIG_DIR"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
DOCKER_MOCK_RUNTIME_DIR="$tmp_dir/docker"
export DOCKER_MOCK_RUNTIME_DIR
DOCKER_MOCK_LOG_FILE="${tmp_dir}/docker.log"
PATH="${ROOT_DIR}/tests/mocks:${PATH}"
SKIP_DOCKER_CHECKS=false
export PATH SKIP_DOCKER_CHECKS DOCKER_MOCK_LOG_FILE

function create_backup() {
  return 0
}

function log_msg() {
  return 0
}

function assert_observation() {
  local network="$1" address="$2" file="$DOMAINS_DIR/refresh-header.test/runtime/observed.csv"
  [ "$(_domain_runtime_get "$file" container_id)" = "$container_id" ] &&
    [ "$(_domain_runtime_get "$file" ownership_token)" = "$token" ] &&
    [ "$(_domain_runtime_get "$file" image)" = nginx:alpine ] &&
    [ "$(_domain_runtime_get "$file" network)" = "$network" ] &&
    [ "$(_domain_runtime_get "$file" address)" = "$address" ] || {
      echo '[Error] Observed metadata does not match the verified refresh snapshot.' >&2; exit 1;
    }
  [ "$(grep -c '^subcommand=inspect ' "$DOCKER_MOCK_LOG_FILE")" -eq 1 ] || {
    echo '[Error] Refresh inspected Docker again while recording its observation.' >&2; exit 1;
  }
}

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,refresh-header.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
port,refresh-header.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

token=0123456789abcdef0123456789abcdef
state_label="$(_backend_identity_state_dir && printf '.')"
state_label="${state_label%.}"
container_id="$(docker run -d --name backend-refresh-header.test --network dockistrate-net \
  --label com.dockistrate.managed=true --label com.dockistrate.role=backend \
  --label "com.dockistrate.state-dir=$state_label" --label com.dockistrate.backend-domain=refresh-header.test \
  --label "com.dockistrate.backend-launch=$token" nginx:alpine)"
_backend_identity_store refresh-header.test "$container_id" "$token"
DOCKER_MOCK_INSPECT_NETWORK_IP='10.0.0.55'
export DOCKER_MOCK_INSPECT_NETWORK_IP

: >"$DOCKER_MOCK_LOG_FILE"
refresh_backend_ips
assert_observation dockistrate-net 10.0.0.55

first_line="$(head -n 1 "$BACKEND_PORTS_FILE" | tr -d '\r')"
if [ "$first_line" != "$STATE_BACKEND_PORTS_HEADER" ]; then
  echo "[Error] refresh_backend_ips dropped CSV header." >&2
  exit 1
fi
if ! grep -Fq 'backend,refresh-header.test,10.0.0.55:18180,dockistrate-net' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_ips did not update backend upstream as expected." >&2
  exit 1
fi

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,refresh-header.test,127.0.0.1:18180,dockistrate-net,,,,,,,,,,,,,,,,,
port,refresh-header.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

DOCKER_MOCK_INSPECT_NETWORK_NAMES='custom-net'
DOCKER_MOCK_INSPECT_NETWORK_IP='10.0.0.88'
export DOCKER_MOCK_INSPECT_NETWORK_NAMES DOCKER_MOCK_INSPECT_NETWORK_IP

# The observed network must come from this verified refresh, even while the
# previously accepted runtime specification still names another network.
printf 'key,value\nnetwork,dockistrate-net\nstate,running\n' >"$DOMAINS_DIR/refresh-header.test/runtime/backend.csv"
: >"$DOCKER_MOCK_LOG_FILE"
refresh_backend_networks
assert_observation custom-net 10.0.0.88

first_line="$(head -n 1 "$BACKEND_PORTS_FILE" | tr -d '\r')"
if [ "$first_line" != "$STATE_BACKEND_PORTS_HEADER" ]; then
  echo "[Error] refresh_backend_networks dropped CSV header." >&2
  exit 1
fi
if ! grep -Fq 'backend,refresh-header.test,10.0.0.88:18180,custom-net' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_networks did not update backend network/upstream as expected." >&2
  exit 1
fi

cat >"$BACKEND_PORTS_FILE" <<EOF
${STATE_BACKEND_PORTS_HEADER}
backend,refresh-header.test,127.0.0.1:18180,custom-net,,,,,,,,,,,,,,,,,
port,refresh-header.test,,,,,18180,18180,http,none,no,off,,off,auto,,,,,,
EOF

DOCKER_MOCK_INSPECT_NETWORK_NAMES=$'dockistrate-net\ncustom-net'
DOCKER_MOCK_INSPECT_NETWORK_MAP='dockistrate-net=10.0.0.10,custom-net=10.0.0.20'
unset DOCKER_MOCK_INSPECT_NETWORK_IP
export DOCKER_MOCK_INSPECT_NETWORK_NAMES DOCKER_MOCK_INSPECT_NETWORK_MAP

: >"$DOCKER_MOCK_LOG_FILE"
refresh_backend_ips
assert_observation custom-net 10.0.0.20

first_line="$(head -n 1 "$BACKEND_PORTS_FILE" | tr -d '\r')"
if [ "$first_line" != "$STATE_BACKEND_PORTS_HEADER" ]; then
  echo "[Error] refresh_backend_ips with multiple networks dropped CSV header." >&2
  exit 1
fi
if ! grep -Fq 'backend,refresh-header.test,10.0.0.20:18180,custom-net' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_ips did not use the stored network IP when multiple networks were attached." >&2
  exit 1
fi
if grep -Fq '10.0.0.10:18180' "$BACKEND_PORTS_FILE"; then
  echo "[Error] refresh_backend_ips used the wrong network IP." >&2
  exit 1
fi

# An unchanged aggregate can still have an obsolete observation. Refresh it
# from the same snapshot without discovering the container twice.
observed="$DOMAINS_DIR/refresh-header.test/runtime/observed.csv"
_domain_runtime_put "$observed" address 10.0.0.99
: >"$DOCKER_MOCK_LOG_FILE"
refresh_backend_ips
assert_observation custom-net 10.0.0.20

# A later ownership failure must leave both aggregate and observed state intact.
state_backend_ports_row_backend unverified.test 10.0.0.44:18181 custom-net >>"$BACKEND_PORTS_FILE"
cp "$BACKEND_PORTS_FILE" "$tmp_dir/before-rows"
cp "$observed" "$tmp_dir/before-observed"
DOCKER_MOCK_INSPECT_NETWORK_MAP='dockistrate-net=10.0.0.10,custom-net=10.0.0.77'
export DOCKER_MOCK_INSPECT_NETWORK_MAP
if refresh_backend_networks >"$tmp_dir/rejected" 2>&1; then
  echo '[Error] Refresh accepted an unverified later backend.' >&2; exit 1
fi
cmp -s "$tmp_dir/before-rows" "$BACKEND_PORTS_FILE" && cmp -s "$tmp_dir/before-observed" "$observed" || {
  echo '[Error] Failed refresh partially published aggregate or observed state.' >&2; exit 1;
}

# The snapshot writer is pure and rejects unsafe values before replacing its
# regular file. Empty stopped addresses must replace any previous running IP.
_backend_container_snapshot refresh-header.test
: >"$DOCKER_MOCK_LOG_FILE"
if domain_config_record_observed_snapshot refresh-header.test custom-net 127.0.0.999; then
  echo '[Error] Observation writer accepted an invalid address.' >&2; exit 1
fi
cmp -s "$tmp_dir/before-observed" "$observed" || { echo '[Error] Invalid observation replaced accepted state.' >&2; exit 1; }
BACKEND_CONTAINER_STATUS=exited
domain_config_record_observed_snapshot refresh-header.test custom-net ''
[ "$(_domain_runtime_get "$observed" state)" = exited ] && [ -z "$(_domain_runtime_get "$observed" address)" ] || {
  echo '[Error] Stopped observation retained the running address.' >&2; exit 1;
}
[ ! -s "$DOCKER_MOCK_LOG_FILE" ] || { echo '[Error] Pure observation writer called Docker.' >&2; exit 1; }

BACKEND_IDENTITY_MIGRATION=true
: >"$DOCKER_MOCK_LOG_FILE"
refresh_backend_networks
assert_observation custom-net 10.0.0.77
[ ! -e "$DOMAINS_DIR/unverified.test/runtime/observed.csv" ] &&
  grep -Fq 'backend,unverified.test,10.0.0.44:18181,custom-net' "$BACKEND_PORTS_FILE" || {
    echo '[Error] Explicit legacy migration changed or adopted an untouched unmanaged route.' >&2; exit 1;
  }

echo "Backend refresh header preservation checks passed."
