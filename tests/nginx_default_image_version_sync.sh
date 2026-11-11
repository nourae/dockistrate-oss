#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/global_csv.sh"
EXPECTED_IMAGE="nginx:1.31.7@sha256:6c3fee1d7a4686ea271e9cc60d9c741cdfbc44ecf11d343025e1cff4c5522f47"
EXPECTED_CERTBOT_IMAGE="certbot/certbot:v5.8.0@sha256:f70ad0adbb7e117f0fe42a63c553f28ea451edabc0148757b6efcd9735acaa20"
LEGACY_IMAGE="nginx:1.31.1"
LEGACY_CERTBOT_IMAGE="certbot/certbot:v5.2.1"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.nginx-image-sync.XXXXXX")"

function cleanup() {
  rm -rf "$TMP_ROOT"
}

function fail_test() {
  echo "[Error] $1" >&2
  exit 1
}

trap cleanup EXIT

# shellcheck source=../lib/config/common.sh
source "$ROOT_DIR/lib/config/common.sh"

[ "$DEFAULT_NGINX_IMAGE" = "$EXPECTED_IMAGE" ] ||
  fail_test "DEFAULT_NGINX_IMAGE is ${DEFAULT_NGINX_IMAGE}; expected ${EXPECTED_IMAGE}."
[ "$DEFAULT_CERTBOT_IMAGE" = "$EXPECTED_CERTBOT_IMAGE" ] ||
  fail_test "DEFAULT_CERTBOT_IMAGE is ${DEFAULT_CERTBOT_IMAGE}; expected ${EXPECTED_CERTBOT_IMAGE}."

# Exact image pins live in the focused guides and reference, not the README.
for path in \
  "$ROOT_DIR/docs/security/image-maintenance.md" \
  "$ROOT_DIR/docs/guides/advanced-nginx-docker-options.md" \
  "$ROOT_DIR/docs/guides/tls-certificates-http3.md" \
  "$ROOT_DIR/docs/function-reference.md" \
  "$ROOT_DIR/docs/function-reference.html"; do
  grep -Fq "$EXPECTED_IMAGE" "$path" ||
    fail_test "$(basename "$path") is not synchronized to ${EXPECTED_IMAGE}."
done

for path in \
  "$ROOT_DIR/docs/guides/advanced-nginx-docker-options.md" \
  "$ROOT_DIR/docs/security/image-maintenance.md" \
  "$ROOT_DIR/docs/function-reference.md" \
  "$ROOT_DIR/docs/function-reference.html"; do
  grep -Fq "$EXPECTED_CERTBOT_IMAGE" "$path" ||
    fail_test "$(basename "$path") is not synchronized to ${EXPECTED_CERTBOT_IMAGE}."
done

# Existing persisted image choices are compatibility state and must not be
# silently rewritten when the default changes.
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/config/persisted_settings.sh
source "$ROOT_DIR/lib/config/persisted_settings.sh"
# shellcheck source=../lib/config/load_config.sh
source "$ROOT_DIR/lib/config/load_config.sh"

GLOBAL_SETTINGS_FILE="$TMP_ROOT/global_settings.csv"
test_global_csv_seed "$GLOBAL_SETTINGS_FILE" NGINX_IMAGE "$LEGACY_IMAGE" CERTBOT_IMAGE "$LEGACY_CERTBOT_IMAGE"
load_config || fail_test "load_config rejected the persisted image fixture."
[ "$NGINX_IMAGE" = "$LEGACY_IMAGE" ] ||
  fail_test "load_config silently replaced persisted image ${LEGACY_IMAGE} with ${NGINX_IMAGE}."
[ "$CERTBOT_IMAGE" = "$LEGACY_CERTBOT_IMAGE" ] ||
  fail_test "load_config silently replaced persisted image ${LEGACY_CERTBOT_IMAGE} with ${CERTBOT_IMAGE}."

echo "Nginx default image version sync tests passed."
