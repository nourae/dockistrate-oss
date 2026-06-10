#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

BACKEND_DOCKER_OPTS_FILE="${tmp_dir}/backend_docker_opts.csv"
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

echo "update-backend docker opts arg-choices checks passed."
