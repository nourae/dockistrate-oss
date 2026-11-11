#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASES=(
  add_cli_rejected add_interactive_rejected
  add_cli_https_rejected add_interactive_https_rejected
  update_cli_rejected update_interactive_rejected update_saved_rejected
  update_cli_unknown_rejected update_interactive_saved_rejected
  nginx_set_rejected nginx_start_rejected nginx_saved_rejected
  add_cli_image_boundary add_interactive_image_boundary
  update_cli_image_boundary update_interactive_image_boundary
  nginx_set_image_boundary nginx_start_image_boundary nginx_saved_image_boundary
)
if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "${BASH_SOURCE[0]}" --case "$test_case"; then
      printf '[tests] PASS: Docker option runtime %s\n' "$test_case"
    else
      printf '[tests] FAIL: Docker option runtime %s\n' "$test_case" >&2
      failed=1
    fi
  done
  exit "$failed"
fi
[ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
case_found=false
for test_case in "${CASES[@]}"; do
  [ "$test_case" != "$2" ] || case_found=true
done
[ "$case_found" = true ] || exit 2
TEST_CASE="$2"

# Keep the real command functions, option parser/validator, and CSV persistence.
# Unrelated network, transaction, and configuration rendering are test doubles.
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=tests/lib/backend_identity_fixture.sh
source "$ROOT_DIR/tests/lib/backend_identity_fixture.sh"
# shellcheck source=../lib/nginx.sh
source "$ROOT_DIR/lib/nginx.sh"
# shellcheck source=../lib/global_settings/set_nginx_docker_opts.sh
source "$ROOT_DIR/lib/global_settings/set_nginx_docker_opts.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_docker_option_runtime.XXXXXX")"
# BSD mktemp retains repeated separators from macOS's trailing-slash TMPDIR.
# Exercise the same valid path spelling on GNU hosts as well, without hiding
# projection preparation behind a canonicalized fixture path or a mock.
case "$TEST_CASE" in
nginx_*_image_boundary) TMP_ROOT="${TMP_ROOT%/*}//${TMP_ROOT##*/}" ;;
esac
trap 'rm -rf "$TMP_ROOT"' EXIT
BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CERTS_DIR="$STATE_DIR/certs"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
ERROR_LOG_DIR="$STATE_DIR/logs/errors"
DEFAULT_NETWORK=dockistrate-net
TARGET_NETWORK="$DEFAULT_NETWORK"
NGINX_IMAGE=managed/nginx:1
NGINX_CONTAINER_NAME=nginx-proxy
NGINX_DOCKER_OPTS='--cpus 1'
NGINX_CONTAINER_CONF_ROOT=/etc/nginx
NGINX_CONTAINER_MAIN_CONF=/etc/nginx/nginx.conf
GLOBAL_SETTINGS_INFO_PREFIX='[Info]'
SKIP_DOCKER_CHECKS=false
INTERACTIVE=false
VISIBILITY_POLICY=full
DOMAIN=options.example.com
BACKEND_IMAGE=managed/backend:1
INVALID_OPTS='--use-api-socket payload.example/alternate:latest'
VALID_OPTS='--use-api-socket --disable-content-trust=false -it=false --cpus 1.5 --env=FOO=bar --future-option=value'
TRACE="$TMP_ROOT/trace"
ARGV="$TMP_ROOT/run-argv"
OUTPUT="$TMP_ROOT/output"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$ACME_WEBROOT_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_DOCKER_OPTS_HEADER" >"$BACKEND_DOCKER_OPTS_FILE"
printf '%s\n' "$NGINX_DOCKER_OPTS" >"$GLOBAL_SETTINGS_FILE"
: >"$TRACE"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function record_action() { printf '%s\n' "$1" >>"$TRACE"; }
function begin_transaction() { record_action transaction; }
function end_transaction_success() { :; }
function _rollback_handler() { exit 1; }
function _config_begin_transaction_if_needed() { :; }
function _config_begin_return_transaction_if_needed() { :; }
function _config_end_transaction_if_started() { :; }
function _nginx_prepare_runtime_rollback() { :; }
function _nginx_release_runtime_rollback() { :; }
function _nginx_mark_runtime_rollback_needed() { :; }
function rollback_pre_hook_add() { :; }
function rollback_pre_hook_remove() { :; }
function log_msg() { :; }
function alias_exists() { return 1; }
function domain_exists() { return 1; }
function backend_exists() { return 0; }
function primary_domain_for() { printf '%s\n' "$1"; }
function get_backend_image() { printf '%s\n' "$BACKEND_IMAGE"; }
function get_container_network_ip() { printf '192.0.2.10\n'; }
function ensure_network_exists() { record_action network; }
function ensure_no_nginx_container_conflict() { return 0; }
function container_running() { return 0; }
function container_exists() { [ "${1:-}" = "backend-$DOMAIN" ]; }
function nginx_container_is_managed() { return 0; }
function capture_tls_decrypt_enabled() { return 1; }
function container_published_port_bindings() { :; }
function assert_host_port_available_or_fail() { return 0; }
function get_all_mapped_port_bindings() { printf '18080/tcp\n'; }
function add_nginx_networks() { return 0; }
function _ensure_nginx_mount_sources() { record_action mounts; }
function pull_image_if_autopull() { record_action pull; }
function _nginx_expected_state_dir_label() { printf '%s' "$STATE_DIR"; }
function remove_container_and_anonymous_volumes() { record_action remove; }
function remove_container_preserving_volumes() { record_action remove; }
function create_nginx_config() { record_action render; }
function update_nginx_config() { :; }
function save_config() {
  record_action save
  printf '%s\n' "$NGINX_DOCKER_OPTS" >"$GLOBAL_SETTINGS_FILE"
}
function add_cert() {
  record_action certificate
  mkdir -p "$CERTS_DIR/letsencrypt/live/${DOMAIN}_443"
}
function docker() {
  record_action "docker:${1:-}"
  if [ "${1:-}" = run ]; then
    shift
    printf '%s\n' "$@" >"$ARGV"
    local arg="" previous=""
    : >"$TMP_ROOT/$NEW_ID.labels"
    for arg in "$@"; do
      if [ "$previous" = --label ]; then printf '%s\n' "$arg" >>"$TMP_ROOT/$NEW_ID.labels"; fi
      previous="$arg"
    done
    printf '%s\n' "$NEW_ID"
  elif [ "${1:-}" = inspect ]; then
    local id="${@: -1}"
    case "${3:-}" in
    *'}}verified{{else}}unverified{{end}}'*)
      [ "$id" = "$OLD_ID" ] || [ "$id" = "$NEW_ID" ] || return 1
      backend_fixture_snapshot "$3" "$id" running "$TMP_ROOT/$id.labels" "$DEFAULT_NETWORK" 192.0.2.10 "$BACKEND_IMAGE"
      ;;
    *) printf '%s\n' "$OLD_ID" ;;
    esac
  fi
}

function invoke_command() {
  local opts="$1"
  case "$TEST_CASE" in
  add_cli_https_*) add_backend "$DOMAIN" "$BACKEND_IMAGE" 8000 https --cert letsencrypt --no-expose --docker-opts "$opts" ;;
  add_interactive_https_*)
    INTERACTIVE=true
    add_backend "$DOMAIN" "$BACKEND_IMAGE" 8000 https '' letsencrypt no "$opts" "$DEFAULT_NETWORK" no
    ;;
  add_cli_*) add_backend "$DOMAIN" "$BACKEND_IMAGE" 8000 http --no-expose --docker-opts "$opts" ;;
  add_interactive_*)
    INTERACTIVE=true
    add_backend "$DOMAIN" "$BACKEND_IMAGE" 8000 http '' '' no "$opts" "$DEFAULT_NETWORK" no
    ;;
  update_cli_*) update_backend "$DOMAIN" --network "$TARGET_NETWORK" --docker-opts "$opts" ;;
  update_interactive_saved_*)
    INTERACTIVE=true
    update_backend "$DOMAIN" '' '' '' "$TARGET_NETWORK"
    ;;
  update_interactive_*)
    INTERACTIVE=true
    update_backend "$DOMAIN" '' '' "$opts" "$TARGET_NETWORK"
    ;;
  update_saved_*) update_backend "$DOMAIN" --network "$TARGET_NETWORK" --image "$BACKEND_IMAGE" ;;
  nginx_set_*) set_nginx_docker_opts "$opts" ;;
  nginx_start_*) start_nginx --docker-opts "$opts" ;;
  nginx_saved_*) recreate_nginx_container "$NGINX_IMAGE" ;;
  *) return 2 ;;
  esac
}

OLD_ID="$(printf '%064d' 1)"
NEW_ID="$(printf '%064d' 2)"
OWNER_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
backend_fixture_seed_labels "$TMP_ROOT/$OLD_ID.labels" "$OWNER_TOKEN" "$DOMAIN" "$STATE_DIR"

case "$TEST_CASE" in
update_*)
  _backend_identity_store "$DOMAIN" "$OLD_ID" "$OWNER_TOKEN"
  state_backend_ports_row_backend "$DOMAIN" '192.0.2.10:8000' "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  set_backend_docker_opts "backend:$DOMAIN" '--cpus 1'
  ;;
esac
case "$TEST_CASE" in
update_*_rejected) TARGET_NETWORK=fresh-network ;;
esac
case "$TEST_CASE" in
update_cli_unknown_rejected) INVALID_OPTS='-Z value' ;;
update_saved_rejected | update_interactive_saved_rejected) set_backend_docker_opts "backend:$DOMAIN" "$INVALID_OPTS" ;;
nginx_saved_rejected) NGINX_DOCKER_OPTS="$INVALID_OPTS" ;;
nginx_saved_image_boundary) NGINX_DOCKER_OPTS="$VALID_OPTS" ;;
esac
cp "$BACKEND_PORTS_FILE" "$TMP_ROOT/ports-before"
cp "$BACKEND_DOCKER_OPTS_FILE" "$TMP_ROOT/backend-options-before"
cp "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/settings-before"

case "$TEST_CASE" in
*_rejected)
  if (invoke_command "$INVALID_OPTS") >"$OUTPUT" 2>&1; then
    fail_test 'Ambiguous Docker options were accepted by a runtime command'
  fi
  grep -Fq 'Failed to parse' "$OUTPUT" || fail_test 'Rejection did not reach Docker option validation'
  if grep -Eq '^(docker:(run|rename|stop|start|rm)|network|certificate|remove|save|render)$' "$TRACE"; then
    fail_test 'Rejected options mutated runtime or persisted settings'
  fi
  case "$TEST_CASE" in
  add_* | update_*)
    if grep -Fxq transaction "$TRACE"; then
      fail_test 'Backend command began a transaction before option validation'
    fi
    ;;
  esac
  [ ! -f "$ARGV" ] || fail_test 'Rejected options reached docker run'
  cmp -s "$BACKEND_PORTS_FILE" "$TMP_ROOT/ports-before" || fail_test 'Rejected options changed backend rows'
  cmp -s "$BACKEND_DOCKER_OPTS_FILE" "$TMP_ROOT/backend-options-before" || fail_test 'Rejected options changed saved backend options'
  cmp -s "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/settings-before" || fail_test 'Rejected options changed global settings'
  if [ "$TEST_CASE" = nginx_saved_rejected ] && [ -s "$TRACE" ]; then
    fail_test 'Saved Nginx options were validated after runtime preparation'
  fi
  ;;
*_image_boundary)
  (invoke_command "$VALID_OPTS") >"$OUTPUT" 2>&1 || fail_test 'Valid Docker options failed in runtime command'
  [ -f "$ARGV" ] || fail_test 'Valid options did not reach docker run'
  # This grammar is intentionally independent of production helpers. It covers
  # only this fixture's options and stops at Docker's first positional image;
  # a mock that scans every token for flags would hide an image takeover.
  args=()
  while IFS= read -r arg; do args+=("$arg"); done <"$ARGV"
  index=0 image_index=-1
  while [ "$index" -lt "${#args[@]}" ]; do
    arg="${args[index]}"
    case "$arg" in
    -d | --use-api-socket | --disable-content-trust=false | -it=false | --env=FOO=bar | --future-option=value)
      index=$((index + 1)) ;;
    --name | --network | --label | -p | -v | --cpus)
      [ $((index + 1)) -lt "${#args[@]}" ] || fail_test 'Docker option lost its value'
      index=$((index + 2)) ;;
    -*) fail_test "Unexpected option in independent argv check: $arg" ;;
    *) image_index="$index"; break ;;
    esac
  done
  [ "$image_index" -ge 0 ] || fail_test 'Docker run has no positional image'
  case "$TEST_CASE" in
  nginx_*)
    [ "${args[image_index]}" = "$NGINX_IMAGE" ] || fail_test 'Nginx managed image was displaced'
    [ "${#args[@]}" -eq $((image_index + 6)) ] || fail_test 'Nginx command argument count changed'
    [ "${args[image_index+1]}" = nginx ] && [ "${args[image_index+2]}" = -g ] &&
      [ "${args[image_index+3]}" = 'daemon off;' ] && [ "${args[image_index+4]}" = -c ] &&
      [ "${args[image_index+5]}" = "$NGINX_CONTAINER_MAIN_CONF" ] || fail_test 'Managed Nginx command changed'
    ;;
  *)
    [ "${args[image_index]}" = "$BACKEND_IMAGE" ] || fail_test 'Backend managed image was displaced'
    [ "${#args[@]}" -eq $((image_index + 1)) ] || fail_test 'Extra backend command material was appended'
    ;;
  esac
  ;;
esac
