#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"

# shellcheck source=../lib/runtime_paths.sh
source "$ROOT_DIR/lib/runtime_paths.sh"
# shellcheck source=../lib/capture/common.sh
source "${CAPTURE_COMMON_SOURCE:-$ROOT_DIR/lib/capture/common.sh}"
# shellcheck source=../lib/nginx/ensure_sslkeylog_library.sh
source "$ROOT_DIR/lib/nginx/ensure_sslkeylog_library.sh"
# shellcheck source=../lib/nginx/recreate_nginx_container.sh
source "$ROOT_DIR/lib/nginx/recreate_nginx_container.sh"
# shellcheck source=lib/empty_proxy_certificate_fixture.sh
source "$ROOT_DIR/tests/lib/empty_proxy_certificate_fixture.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_recreate_keylog_state.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
# Keep runtime guards and exact Docker paths consistent through temporary aliases.
tmp_dir="$(cd "$tmp_dir" && pwd -P)"

BASE_DIR="$tmp_dir/base[glob]"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
CAPTURE_DIR="$STATE_DIR/pcaps"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
NGINX_IMAGE="nginx:test"
NGINX_CONTAINER_NAME="nginx-proxy"
DEFAULT_NETWORK="dockistrate-net"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CAPTURE_KEYS_DIR="/var/log/nginx/keys"
SSLKEYLOG_LIB_SOURCE_FILE="$tmp_dir/sslkeylogfile.c"
printf '%s\n' 'int keylog_fixture;' >"$SSLKEYLOG_LIB_SOURCE_FILE"
EXPECTED_SOURCE_SHA256="$(_sslkeylog_source_fingerprint)"
SSLKEYLOG_LIB_BUILD_FILE="$STATE_DIR/tmp/sslkeylogfile.so"
NGINX_SSLKEYLOG_LIB_PATH="/usr/local/lib/dockistrate/sslkeylogfile.so"
NGINX_DOCKER_OPTS=""
DOCKISTRATE_MANAGED_LABEL_KEY="com.dockistrate.managed"
DOCKISTRATE_ROLE_LABEL_KEY="com.dockistrate.role"
DOCKISTRATE_STATE_DIR_LABEL_KEY="com.dockistrate.state-dir"
DOCKISTRATE_ROLE_PROXY="proxy"
NGINX_CONTAINER_CONF_ROOT="/etc/nginx/dockistrate"
NGINX_CONTAINER_MAIN_CONF="$NGINX_CONTAINER_CONF_ROOT/nginx.conf"
RUN_ARGV="$tmp_dir/docker-run.argv"
ENSURE_STATUS=1
DOCKER_STATUS=1

pull_calls=0
conflict_calls=0
network_calls=0
ensure_calls=0
remove_calls=0
rollback_mark_calls=0
docker_calls=0
tamper_after_pull_dir=""
tamper_after_pull_target=""

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function mode_of() {
  local path="$1" mode=""
  if mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    printf '%s' "$mode"
    return 0
  fi
  stat -f '%Lp' "$path"
}

function reset_case() {
  rm -rf "$BASE_DIR"
  mkdir -p "$CONFIG_DIR" "$CAPTURE_DIR"
  pull_calls=0
  conflict_calls=0
  network_calls=0
  ensure_calls=0
  remove_calls=0
  rollback_mark_calls=0
  docker_calls=0
  ENSURE_STATUS=1
  DOCKER_STATUS=1
  rm -f "$RUN_ARGV"
  tamper_after_pull_dir=""
  tamper_after_pull_target=""
}

function write_tls_state() {
  local keylog_file="$1"
  mkdir -p "$CONFIG_DIR"
  cat >"$CAPTURE_TLS_STATE_FILE" <<EOF
enabled=true
keylog_file=${keylog_file}
EOF
}

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function normalize_nginx_image() { printf '%s\n' "${1:-}"; }
function ensure_no_nginx_container_conflict() {
  conflict_calls=$((conflict_calls + 1))
  return 0
}
function get_all_mapped_port_bindings() { return 0; }
function ensure_network_exists() {
  network_calls=$((network_calls + 1))
  return 0
}
function create_nginx_config() { mkdir -p "$NGINX_CONFIG_DIR"; : >"$NGINX_CONFIG_DIR/nginx.conf"; }
function nginx_container_is_managed() { return 0; }
function container_running() { return 0; }
function container_published_port_bindings() { return 0; }
function pull_image_if_autopull() {
  pull_calls=$((pull_calls + 1))
  if [ -n "$tamper_after_pull_dir" ]; then
    rm -rf "$tamper_after_pull_dir"
    ln -s "$tamper_after_pull_target" "$tamper_after_pull_dir"
  fi
  return 0
}
function ensure_sslkeylog_library() {
  ensure_calls=$((ensure_calls + 1))
  return "$ENSURE_STATUS"
}
function _nginx_mark_runtime_rollback_needed() {
  rollback_mark_calls=$((rollback_mark_calls + 1))
}
function remove_container_and_anonymous_volumes() {
  remove_calls=$((remove_calls + 1))
}
function docker() {
  docker_calls=$((docker_calls + 1))
  printf '%s\0' "$@" >"$RUN_ARGV"
  return "$DOCKER_STATUS"
}

function _nginx_expected_state_dir_label() { printf '%s' "$STATE_DIR"; }
function add_nginx_networks() { return 0; }
function log_msg() { :; }

function assert_no_container_mutation() {
  local label="$1"
  [ "$conflict_calls" -eq 0 ] || fail "${label}: nginx conflict check should not run for invalid state."
  [ "$network_calls" -eq 0 ] || fail "${label}: docker network preflight should not run for invalid state."
  [ "$pull_calls" -eq 0 ] || fail "${label}: image pull preflight should not run for invalid state."
  [ "$ensure_calls" -eq 0 ] || fail "${label}: TLS keylog helper build should not run for invalid state."
  [ "$remove_calls" -eq 0 ] || fail "${label}: nginx container should not be removed for invalid state."
  [ "$rollback_mark_calls" -eq 0 ] || fail "${label}: runtime rollback should not be marked for invalid state."
  [ "$docker_calls" -eq 0 ] || fail "${label}: docker run should not execute for invalid state."
}

function run_invalid_keylog_case() {
  local label="$1" keylog_file="$2" protected_file="${3:-}" output_file="" output="" status=0
  output_file="$tmp_dir/${label// /_}.log"

  write_tls_state "$keylog_file"
  recreate_nginx_container "$NGINX_IMAGE" >"$output_file" 2>&1 || status=$?
  output="$(cat "$output_file")"
  [ "$status" -ne 0 ] || fail "${label}: recreate_nginx_container should reject invalid TLS decrypt state."
  assert_no_container_mutation "$label"
  if [ -n "$protected_file" ]; then
    [ "$(mode_of "$protected_file")" = "644" ] || fail "${label}: invalid TLS state changed protected file mode."
  fi
  case "$output" in
  *"invalid TLS decrypt state"* | *"TLS key log file outside"* | *"Refusing to use"*) ;;
  *)
    printf '%s\n' "$output" >&2
    fail "${label}: expected invalid TLS state error."
    ;;
  esac
}

outside_file="$tmp_dir/outside-keylog.log"
: >"$outside_file"
chmod 644 "$outside_file"
reset_case
run_invalid_keylog_case "external keylog path" "$outside_file" "$outside_file"

traversal_target="$CAPTURE_DIR/outside-keylog.log"
reset_case
: >"$traversal_target"
chmod 644 "$traversal_target"
run_invalid_keylog_case "traversal keylog path" "$CAPTURE_DIR/tls-keys/../outside-keylog.log" "$traversal_target"

wrong_keylog_dir="$CAPTURE_DIR/tls-keys-extra"
reset_case
mkdir -p "$wrong_keylog_dir"
wrong_keylog_file="$wrong_keylog_dir/tlskeys.log"
: >"$wrong_keylog_file"
chmod 644 "$wrong_keylog_file"
run_invalid_keylog_case "wrong state subdirectory keylog path" "$wrong_keylog_file" "$wrong_keylog_file"

symlink_target="$tmp_dir/symlink-target"
reset_case
mkdir -p "$symlink_target"
ln -s "$symlink_target" "$CAPTURE_DIR/tls-keys"
symlink_file="$symlink_target/tlskeys.log"
: >"$symlink_file"
chmod 644 "$symlink_file"
run_invalid_keylog_case "symlinked keylog directory" "$CAPTURE_DIR/tls-keys/tlskeys.log" "$symlink_file"

reset_case
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_file="$valid_keylog_dir/tlskeys.log"
mkdir -p "$valid_keylog_dir"
: >"$valid_keylog_file"
external_race_dir="$tmp_dir/race-external"
external_race_file="$external_race_dir/tlskeys.log"
mkdir -p "$external_race_dir"
: >"$external_race_file"
chmod 644 "$external_race_file"
write_tls_state "$valid_keylog_file"
tamper_after_pull_dir="$valid_keylog_dir"
tamper_after_pull_target="$external_race_dir"
race_output_file="$tmp_dir/race_keylog_path.log"
status=0
recreate_nginx_container "$NGINX_IMAGE" >"$race_output_file" 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "late symlinked keylog directory should fail closed."
[ "$ensure_calls" -eq 0 ] || fail "late symlinked keylog directory should fail before helper build."
[ "$remove_calls" -eq 0 ] || fail "late symlinked keylog directory should fail before container removal."
[ "$rollback_mark_calls" -eq 0 ] || fail "late symlinked keylog directory should fail before rollback marking."
[ "$docker_calls" -eq 0 ] || fail "late symlinked keylog directory should fail before docker run."
[ "$(mode_of "$external_race_file")" = "644" ] || fail "late symlinked keylog directory changed external keylog file mode."
case "$(cat "$race_output_file")" in
*"Refusing to use"*) ;;
*)
  cat "$race_output_file" >&2
  fail "late symlinked keylog directory should report runtime path rejection."
  ;;
esac

reset_case
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_file="$valid_keylog_dir/tlskeys.log"
mkdir -p "$valid_keylog_dir"
: >"$valid_keylog_file"
chmod 644 "$valid_keylog_file"
write_tls_state "$valid_keylog_file"
status=0
recreate_nginx_container "$NGINX_IMAGE" >/dev/null 2>&1 || status=$?
[ "$status" -ne 0 ] || fail "valid keylog path should still fail when helper build is stubbed to fail."
[ "$conflict_calls" -eq 1 ] || fail "valid keylog path should reach nginx conflict check."
[ "$network_calls" -eq 1 ] || fail "valid keylog path should reach docker network preflight."
[ "$pull_calls" -eq 1 ] || fail "valid keylog path should reach image pull preflight."
[ "$ensure_calls" -eq 1 ] || fail "valid keylog path should reach TLS keylog helper build."
[ "$(mode_of "$valid_keylog_file")" = "600" ] || fail "valid keylog path should keep restrictive permissions."
[ "$remove_calls" -eq 0 ] || fail "helper build failure should happen before container removal."
[ "$rollback_mark_calls" -eq 0 ] || fail "helper build failure should happen before rollback marking."
[ "$docker_calls" -eq 0 ] || fail "helper build failure should happen before docker run."

# Exercise the real mount helper through its caller. The caller's output
# variable is keylog_name; a helper local with that name silently loses the
# basename and sends only the key directory to SSLKEYLOGFILE.
reset_case
valid_keylog_dir="$CAPTURE_DIR/tls-keys"
valid_keylog_name="tlskeys_saved-session.ABC123"
valid_keylog_file="$valid_keylog_dir/$valid_keylog_name"
mkdir -p "$valid_keylog_dir"
printf '%s\n' 'existing session key evidence' >"$valid_keylog_file"
chmod 600 "$valid_keylog_file"
write_tls_state "$valid_keylog_file"
ENSURE_STATUS=0
DOCKER_STATUS=0
recreate_nginx_container "$NGINX_IMAGE" >"$tmp_dir/valid-recreate.log" 2>&1 || {
  cat "$tmp_dir/valid-recreate.log" >&2
  fail "valid TLS state should recreate the proxy after helper build succeeds."
}
[ "$ensure_calls" -eq 1 ] && [ "$docker_calls" -eq 1 ] || fail "valid TLS recreate did not build and launch exactly once."
printf '%s\0' run -d --name "$NGINX_CONTAINER_NAME" \
  --label "$DOCKISTRATE_MANAGED_LABEL_KEY=true" \
  --label "$DOCKISTRATE_ROLE_LABEL_KEY=$DOCKISTRATE_ROLE_PROXY" \
  --label "$DOCKISTRATE_STATE_DIR_LABEL_KEY=$STATE_DIR" \
  -v "$NGINX_CONFIG_DIR:$NGINX_CONTAINER_CONF_ROOT:ro" \
  -v "$tmp_dir/proxy_certs/empty-generation:/etc/letsencrypt:ro" \
  -v "$valid_keylog_dir:$NGINX_CAPTURE_KEYS_DIR" \
  -v "$SSLKEYLOG_LIB_BUILD_FILE:$NGINX_SSLKEYLOG_LIB_PATH:ro" \
  -e "SSLKEYLOGFILE=$NGINX_CAPTURE_KEYS_DIR/$valid_keylog_name" \
  -e "LIBSSL_SSLKEYLOGFILE=$NGINX_CAPTURE_KEYS_DIR/$valid_keylog_name" \
  -e "DOCKISTRATE_SSLKEYLOG_SOURCE_SHA256=$EXPECTED_SOURCE_SHA256" \
  -e "LD_PRELOAD=$NGINX_SSLKEYLOG_LIB_PATH" \
  -v "$ACME_WEBROOT_DIR:/var/www/certbot:ro" --network "$DEFAULT_NETWORK" \
  "$NGINX_IMAGE" nginx -g 'daemon off;' -c "$NGINX_CONTAINER_MAIN_CONF" >"$tmp_dir/expected-run.argv"
cmp -s "$tmp_dir/expected-run.argv" "$RUN_ARGV" || fail "TLS recreate Docker argv must use the exact saved keylog basename and current helper source digest."
[ "$(cat "$valid_keylog_file")" = 'existing session key evidence' ] || fail "valid TLS recreate changed existing keylog bytes."
[ "$(mode_of "$valid_keylog_file")" = 600 ] || fail "valid TLS recreate changed restrictive keylog permissions."

echo "recreate-nginx TLS keylog state containment checks passed."
