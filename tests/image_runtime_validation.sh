#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/config/image_uses_latest_tag.sh
source "$ROOT_DIR/lib/config/image_uses_latest_tag.sh"
# shellcheck source=../lib/config/pull_image_if_autopull.sh
source "$ROOT_DIR/lib/config/pull_image_if_autopull.sh"
# shellcheck source=../lib/nginx/common.sh
source "$ROOT_DIR/lib/nginx/common.sh"
# shellcheck source=../lib/nginx/start_nginx.sh
source "$ROOT_DIR/lib/nginx/start_nginx.sh"
# shellcheck source=../lib/nginx/recreate_nginx_container.sh
source "$ROOT_DIR/lib/nginx/recreate_nginx_container.sh"
# shellcheck source=../lib/nginx/ensure_sslkeylog_library.sh
source "$ROOT_DIR/lib/nginx/ensure_sslkeylog_library.sh"
# shellcheck source=../lib/nginx/describe_image_with_local_state.sh
source "$ROOT_DIR/lib/nginx/describe_image_with_local_state.sh"
# shellcheck source=../lib/certs/add_cert.sh
source "$ROOT_DIR/lib/certs/add_cert.sh"
# shellcheck source=../lib/certs/_renew_letsencrypt_cert.sh
source "$ROOT_DIR/lib/certs/_renew_letsencrypt_cert.sh"
# shellcheck source=../lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=tests/lib/backend_identity_fixture.sh
source "$ROOT_DIR/tests/lib/backend_identity_fixture.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_image_runtime.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
TRACE="$TMP_ROOT/trace"
OUTPUT="$TMP_ROOT/output"
BACKEND_PORTS_FILE="$TMP_ROOT/backend_ports.csv"
CONFIG_DIR="$TMP_ROOT/config"
STATE_DIR="$TMP_ROOT/state"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
mkdir -p "$CONFIG_DIR" "$STATE_DIR"
CERTS_DIR="$TMP_ROOT/certs"
ACME_WEBROOT_DIR="$TMP_ROOT/acme"
NGINX_DOCKER_OPTS=""
DEFAULT_NETWORK="dockistrate-net"
NGINX_CONTAINER_NAME="nginx-proxy"
SSLKEYLOG_LIB_SOURCE_FILE="$TMP_ROOT/helper.c"
SSLKEYLOG_LIB_BUILD_FILE="$TMP_ROOT/helper.so"
SSLKEYLOG_LIB_BUILD_DIR="$TMP_ROOT/build"
SSLKEYLOG_LIB_BUILD_META_FILE="$TMP_ROOT/helper.meta"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
csv_join_row backend images.example.com 192.0.2.10:8000 dockistrate-net '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' >>"$BACKEND_PORTS_FILE"
printf 'fixture\n' >"$SSLKEYLOG_LIB_SOURCE_FILE"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function side_effect() { printf '%s\n' "$1" >>"$TRACE"; return 1; }
function docker() {
  if [ "${1:-}" = inspect ] && [ "${@: -1}" = "$OWNED_ID" ] && [[ "${3:-}" == *'}}verified{{else}}unverified{{end}}'* ]]; then
    backend_fixture_snapshot "$3" "$OWNED_ID" running "$TMP_ROOT/owner.labels" dockistrate-net 192.0.2.10 "$OBSERVED_IMAGE"
    return 0
  fi
  side_effect docker
}
function begin_transaction() { side_effect transaction; }
function _config_begin_transaction_if_needed() { side_effect transaction; }
function ensure_network_exists() { side_effect network; }
function ensure_no_nginx_container_conflict() { side_effect conflict; }
function check_certbot_installed() { side_effect certbot; }
function normalize_docker_opts_for_storage() { printf '%s\n' "$1"; }
function resolve_backend_domain() { :; }
function backend_exists() { return 0; }
function get_backend_image() { printf '%s\n' "$SAVED_IMAGE"; }
function get_backend_docker_opts() { :; }
function ensure_valid_or_prompt() {
  # Exercise the same real image validator without entering interactive input
  # when this fixture intentionally supplies a malformed explicit image.
  if [ "$5" = is_valid_image_ref ]; then require_valid_image_ref "$2" 'backend image'; else "$5" "$2"; fi
}

function run_case() {
  case "$1" in
  pull) pull_image_if_autopull "$SAVED_IMAGE" "test image" ;;
  pull_skip) SKIP_DOCKER_CHECKS=true pull_image_if_autopull "$SAVED_IMAGE" "test image" ;;
  start) start_nginx ;;
  recreate) recreate_nginx_container ;;
  keylog) ensure_sslkeylog_library ;;
  describe) describe_image_with_local_state "$SAVED_IMAGE" always "test image" nginx-proxy ;;
  add_cert) add_cert images.example.com 443 letsencrypt ;;
  renew_cert) _renew_letsencrypt_cert images.example.com ;;
  update_cli)
    case "$SAVED_IMAGE" in
    *$'\n'*) update_backend images.example.com --image "$SAVED_IMAGE" --docker-opts '--cpus 1' --network fresh-net ;;
    *) update_backend images.example.com --docker-opts '--cpus 1' --network fresh-net ;;
    esac
    ;;
  update_interactive)
    case "$SAVED_IMAGE" in
    *$'\n'*) INTERACTIVE=true update_backend images.example.com "$SAVED_IMAGE" '' '--cpus 1' fresh-net ;;
    *) INTERACTIVE=true update_backend images.example.com '' '' '--cpus 1' fresh-net ;;
    esac
    ;;
  esac
}

OWNED_ID="$(printf '%064d' 1)"
OWNER_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OBSERVED_IMAGE=nginx:alpine
backend_fixture_seed_labels "$TMP_ROOT/owner.labels" "$OWNER_TOKEN" images.example.com "$STATE_DIR"
_backend_identity_store images.example.com "$OWNED_ID" "$OWNER_TOKEN"

cases=(pull pull_skip start recreate keylog describe add_cert renew_cert update_cli update_interactive)
invalid_refs=('-p80:80' '--privileged' $'library/nginx\n--privileged' 'repo;command')
for SAVED_IMAGE in "${invalid_refs[@]}"; do
  # Docker image metadata is one line; multiline input is tested at the explicit
  # image argument boundary while single-line invalid cached values remain raw.
  case "$SAVED_IMAGE" in *$'\n'*) OBSERVED_IMAGE=nginx:alpine ;; *) OBSERVED_IMAGE="$SAVED_IMAGE" ;; esac
  for test_case in "${cases[@]}"; do
    : >"$TRACE"
    if (NGINX_IMAGE="$SAVED_IMAGE" CERTBOT_IMAGE="$SAVED_IMAGE" SKIP_DOCKER_CHECKS=false INTERACTIVE=false run_case "$test_case") >"$OUTPUT" 2>&1; then
      fail_test "$test_case accepted an invalid image"
    fi
    [ ! -s "$TRACE" ] || fail_test "$test_case performed runtime work before image validation"
    grep -Fq '[Error] Invalid Docker image reference' "$OUTPUT" || fail_test "$test_case did not report image validation failure"
  done
done

# An explicit valid choice can replace an invalid cached image before preflight.
SAVED_IMAGE='--privileged'
: >"$TRACE"
if (NGINX_IMAGE="$SAVED_IMAGE" SKIP_DOCKER_CHECKS=false start_nginx --nginx-image registry.example.com:5000/team/repo:tag) >"$OUTPUT" 2>&1; then
  fail_test 'start-nginx should stop at the conflict test double'
fi
grep -qx conflict "$TRACE" || fail_test 'valid Nginx override did not reach normal preflight'
: >"$TRACE"
OBSERVED_IMAGE='--privileged'
if (INTERACTIVE=false update_backend images.example.com --image registry.example.com:5000/team/repo:tag) >"$OUTPUT" 2>&1; then
  fail_test 'update-backend should stop at the transaction test double'
fi
grep -qx transaction "$TRACE" || fail_test 'valid backend override did not reach normal preflight'

# Valid references remain usable with pull checks disabled and pinned images.
for SAVED_IMAGE in 'registry.example.com:5000/team/my__image--worker:tag' '[::1]:5000/repo:tag'; do
  : >"$TRACE"
  SKIP_DOCKER_CHECKS=true pull_image_if_autopull "$SAVED_IMAGE" "test image" >"$OUTPUT" 2>&1 || fail_test 'valid image failed skipped pull'
  SKIP_DOCKER_CHECKS=false pull_image_if_autopull "$SAVED_IMAGE" "test image" >"$OUTPUT" 2>&1 || fail_test 'valid pinned image failed pull preflight'
  [ ! -s "$TRACE" ] || fail_test 'pinned or skipped image performed unnecessary Docker work'
done
printf 'Image runtime preflight checks passed (40 rejection cases, valid overrides and pinned images).\n'
