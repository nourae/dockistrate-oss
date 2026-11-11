#!/usr/bin/env bash
# Shared settings are consumed by the production validation launcher.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backends.sh"
source "$ROOT_DIR/lib/domain_config/nginx_validation.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-nginx-validation.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
NGINX_CONFIG_DIR="$TEST_WORK/config"
NGINX_CONTAINER_CONF_ROOT=/etc/nginx/dockistrate
NGINX_CONTAINER_MAIN_CONF=/etc/nginx/dockistrate/nginx.conf
ACME_WEBROOT_DIR="$TEST_WORK/challenge"
DEFAULT_NETWORK=validation-test
NGINX_IMAGE=nginx:test
SKIP_DOCKER_CHECKS=false

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function domain_config_active() { return 0; }
function _nginx_verify_certificate_projection() { [ "$1" = "$TEST_WORK/projection" ]; }
function _domain_runtime_ensure_network() { [ "$2" = "$DEFAULT_NETWORK" ]; }
function pull_image_if_autopull() { [ "$1" = "$NGINX_IMAGE" ]; }
function docker() {
  printf '%s\n' "$@" >"$TEST_WORK/launch"
  return "${MOCK_VALIDATE_STATUS:-0}"
}

# Static endpoint identities belong only to the serving container. Exercise
# separate and attached values while keeping capabilities, DNS and exact data
# arguments needed by nginx -t. A label value that looks like an option is data.
for form in separate attached; do
  common="--label '--ip' --env 'VALUE=spaces stay together' --cap-add NET_ADMIN --dns 192.0.2.53 --read-only --tmpfs /tmp"
  case "$form" in
  separate)
    endpoint='--ip 192.0.2.10 --ip6 2001:db8::10 --mac-address 02:42:ac:11:00:10 --link-local-ip 169.254.1.10 --network-alias serving --net-alias secondary'
    lifecycle='--name serving-proxy --cidfile /tmp/serving.cid --restart always -p 80:80 --detach --publish-all'
    ;;
  attached)
    endpoint='--ip=192.0.2.10 --ip6=2001:db8::10 --mac-address=02:42:ac:11:00:10 --link-local-ip=169.254.1.10 --network-alias=serving --net-alias=secondary'
    lifecycle='--name=serving-proxy --cidfile=/tmp/serving.cid --restart=always --publish=80:80 --detach=true --publish-all=true'
    ;;
  esac
  NGINX_DOCKER_OPTS="$endpoint $common $lifecycle"
  original="$NGINX_DOCKER_OPTS"
  domain_config_validate_nginx_candidate "$TEST_WORK/projection"
  printf '%s\n' run --rm --label --ip --env 'VALUE=spaces stay together' --cap-add NET_ADMIN --dns 192.0.2.53 --read-only --tmpfs /tmp \
    --detach=false --interactive=false --tty=false \
    -v "$NGINX_CONFIG_DIR:$NGINX_CONTAINER_CONF_ROOT:ro" -v "$TEST_WORK/projection:/etc/letsencrypt:ro" \
    -v "$ACME_WEBROOT_DIR:/var/www/certbot:ro" --network "$DEFAULT_NETWORK" "$NGINX_IMAGE" nginx -t -c "$NGINX_CONTAINER_MAIN_CONF" >"$TEST_WORK/expected"
  cmp -s "$TEST_WORK/launch" "$TEST_WORK/expected" || { diff -u "$TEST_WORK/expected" "$TEST_WORK/launch" >&2 || true; fail_test "Incorrect $form validation arguments"; }
  [ "$NGINX_DOCKER_OPTS" = "$original" ] || fail_test 'Validation rewrote serving container options'
done
# Short boolean bundles remain valid serving options. Explicit final overrides
# keep validation synchronous and preserve attached/separate data boundaries.
for lifecycle in '-dit' '-d=true' '-dit=false' '-dil owner=--ip'; do
  NGINX_DOCKER_OPTS="$lifecycle --env VALUE=-d --interactive=true --tty=true"
  domain_config_validate_nginx_candidate "$TEST_WORK/projection"
  overrides="$(awk '/^--detach=false$/ {print; getline; print; getline; print; getline; print}' "$TEST_WORK/launch")"
  [ "$overrides" = "$(printf '%s\n' --detach=false --interactive=false --tty=false -v)" ] || fail_test 'Validation lacks final foreground/terminal overrides'
  grep -Fxq 'VALUE=-d' "$TEST_WORK/launch" || fail_test 'A detach-shaped environment value was altered'
done
MOCK_VALIDATE_STATUS=1
if domain_config_validate_nginx_candidate "$TEST_WORK/projection" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Validation launch failure was ignored'; fi
grep -q 'Candidate Nginx configuration failed validation' "$TEST_WORK/rejected" || fail_test 'Launch failure omitted its activation diagnostic'
printf '[PASS] candidate validation retains runtime capabilities without claiming serving endpoints\n'
