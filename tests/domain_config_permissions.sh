#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/permissions.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_domain_permissions.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STATE_DIR/domains/example.com/config" "$STATE_DIR/domains/example.com/runtime/applied" \
  "$STATE_DIR/domains/example.com/certs/custom-443" "$STATE_DIR/shared/acme/accounts"
printf 'position,argument\n1,--env\n2,TOKEN=test\n' >"$STATE_DIR/domains/example.com/config/docker_options.csv"
printf 'image,container_port,network,state\ntest,,,\n' >"$STATE_DIR/domains/example.com/runtime/backend.csv"
printf 'test key fixture\n' >"$STATE_DIR/domains/example.com/certs/custom-443/privkey.pem"
printf '{}\n' >"$STATE_DIR/shared/acme/accounts/private_key.json"
chmod 666 "$STATE_DIR/domains/example.com/config/docker_options.csv" "$STATE_DIR/domains/example.com/runtime/backend.csv" \
  "$STATE_DIR/domains/example.com/certs/custom-443/privkey.pem" "$STATE_DIR/shared/acme/accounts/private_key.json"
_ensure_domain_layout_permissions
for path in "$STATE_DIR/domains/example.com/config/docker_options.csv" "$STATE_DIR/domains/example.com/runtime/backend.csv" \
  "$STATE_DIR/domains/example.com/certs/custom-443/privkey.pem" "$STATE_DIR/shared/acme/accounts/private_key.json"; do
  mode="$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path")"
  [ "$mode" = 600 ] || { echo "[Error] Private file is not protected: $path ($mode)" >&2; exit 1; }
done
_is_private_runtime_file "$STATE_DIR/domains/example.com/config/docker_options.csv"
_is_private_runtime_file "$STATE_DIR/domains/example.com/runtime/backend.csv"
echo 'domain config permission checks passed.'
