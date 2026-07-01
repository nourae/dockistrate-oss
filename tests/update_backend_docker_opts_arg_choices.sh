#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backends/common.sh
source "$ROOT_DIR/lib/backends/common.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/arg_choices_network_docker.sh
source "$ROOT_DIR/lib/cli/arg_choices_network_docker.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_update_backend_opts_choices.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

DEFAULT_NETWORK="dockistrate-net"
BACKEND_DOCKER_OPTS_FILE="${tmp_dir}/backend_docker_opts.csv"
BACKEND_PORTS_FILE="${tmp_dir}/backend_ports.csv"
PATH="${ROOT_DIR}/tests/mocks:${PATH}"
export PATH
CURRENT_ARGS=("example.test")

cat >"$BACKEND_DOCKER_OPTS_FILE" <<'EOF_OPTS'
key,docker_options
backend:example.test,--label app=demo
EOF_OPTS

choices_with_opts="$(__arg_choices_docker_opts "update-backend")"
if ! grep -Fq "__CLEAR__|Clear current options" <<<"$choices_with_opts"; then
  echo "[Error] Expected clear choice when backend has stored docker opts." >&2
  exit 1
fi

printf '%s\n' "key,docker_options" >"$BACKEND_DOCKER_OPTS_FILE"
choices_without_opts="$(__arg_choices_docker_opts "update-backend")"
if grep -Fq "__CLEAR__|Clear current options" <<<"$choices_without_opts"; then
  echo "[Error] Clear choice should not be shown when backend has no stored docker opts." >&2
  exit 1
fi

cat >"$BACKEND_PORTS_FILE" <<EOF_PORTS
${STATE_BACKEND_PORTS_HEADER}
backend,example.test,172.30.0.2:8080,custom-net,,,,,,,,,,,,,,,,,
port,example.test,,,,,80,8080,http,none,no,off,,off,auto,,,,,,
EOF_PORTS

DOCKER_MOCK_NETWORK_NAMES=$'dockistrate-net\ncustom-net\nother-net'
export DOCKER_MOCK_NETWORK_NAMES
CLI_DOCKER_NETWORKS_CACHE_TOKEN=""
CLI_DOCKER_NETWORKS_CACHE_VALUE=""

network_choices="$(__arg_choices_network "update-backend")"
first_choice="$(printf '%s\n' "$network_choices" | awk 'NF { print; exit }')"
if [ "$first_choice" != "custom-net" ]; then
  echo "[Error] update-backend network choices should put the current backend network first." >&2
  printf '%s\n' "$network_choices" >&2
  exit 1
fi
if ! grep -Fxq "dockistrate-net" <<<"$network_choices"; then
  echo "[Error] update-backend network choices should include the default network." >&2
  exit 1
fi
if ! grep -Fxq "other-net" <<<"$network_choices"; then
  echo "[Error] update-backend network choices should include Docker networks." >&2
  exit 1
fi
if ! grep -Fxq "__MANUAL__|Enter manually..." <<<"$network_choices"; then
  echo "[Error] update-backend network choices should include manual entry." >&2
  exit 1
fi

echo "update-backend docker opts arg-choices checks passed."
