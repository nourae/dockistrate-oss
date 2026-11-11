#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
for module in backups backends nginx ports tls mtls headers http_version security_rules nginx_directives; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backend_ownership.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
original_state="$STATE_DIR"
# Keep every runtime path in this fixture, including transaction snapshots.
for variable in $(compgen -A variable); do
  case "$variable" in
  *_FILE|*_DIR|*_DB)
    value="${!variable}"
    case "$value" in "$original_state"|"$original_state"/*) printf -v "$variable" '%s' "$FIXTURE/state${value#"$original_state"}" ;; esac
    ;;
  esac
done
BASE_DIR="$FIXTURE"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
PATH="$ROOT_DIR/tests/mocks:$PATH"
DOCKER_MOCK_RUNTIME_DIR="$FIXTURE/docker"
DOCKER_MOCK_LOG_FILE="$FIXTURE/docker.log"
export PATH DOCKER_MOCK_RUNTIME_DIR DOCKER_MOCK_LOG_FILE
SKIP_DOCKER_CHECKS=false
INTERACTIVE=false
DOMAIN=identity.test
CNAME=backend-identity.test
TOKEN=0123456789abcdef0123456789abcdef

function fail() { printf '[Error] %s: %s\n' "${CASE:-setup}" "$*" >&2; exit 1; }
function create_backup() { :; }
function log_msg() { :; }
function capture_docker_logs() { :; }

# Static expected bytes protect Go-template quoting on Bash 3 as well as 5.
# This does not reimplement the encoder used by the production helper.
literal_input=$'state\\path\n"quoted"\t\r'
literal_expected='"state\\path\x0a\"quoted\"\x09\x0d"'
[ "$(_backend_identity_go_literal "$literal_input")" = "$literal_expected" ] || fail 'Go ownership predicate literal changed path bytes'
printf '[PASS] ownership predicate preserves quotes, backslashes and control bytes\n'

function prepare_case() {
  CASE="$1"
  rm -rf "$FIXTURE/state" "$DOCKER_MOCK_RUNTIME_DIR" "$FIXTURE/config.before" "$FIXTURE/docker.before"
  mkdir -p "$CONFIG_DIR" "$NGINX_HTTP_CONF_DIR" "$TMP_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CERTS_DIR"
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  state_backend_ports_row_backend "$DOMAIN" 10.0.0.5:8000 dockistrate-net >>"$BACKEND_PORTS_FILE"
  printf 'proxy_pass http://10.0.0.5:8000;\n' >"$NGINX_HTTP_CONF_DIR/backends.conf"
  local managed=true role=backend domain="$DOMAIN" state="" token="$TOKEN"
  state="$(_backend_identity_state_dir && printf '.')" || fail 'cannot resolve fixture state root'
  state="${state%.}"
  case "$CASE" in
  unowned) managed=''; role=''; domain=''; state=''; token='' ;;
  wrong_token) token=abcdef0123456789abcdef0123456789 ;;
  wrong_domain) domain=foreign.test ;;
  wrong_root) state="$FIXTURE/other-state" ;;
  wrong_role) role=proxy ;;
  wrong_managed) managed=false ;;
  esac
  CONTAINER_ID="$(docker run -d --name "$CNAME" --network foreign-net \
    --label "com.dockistrate.managed=$managed" --label "com.dockistrate.role=$role" \
    --label "com.dockistrate.state-dir=$state" --label "com.dockistrate.backend-domain=$domain" \
    --label "com.dockistrate.backend-launch=$token" nginx:alpine)"
  _backend_identity_store "$DOMAIN" "$CONTAINER_ID" "$TOKEN"
  case "$CASE" in
  stale_id) _backend_identity_store "$DOMAIN" "$(printf '%064d' 1)" "$TOKEN" ;;
  missing_state) rm -f "$BACKEND_IDENTITY_FILE" ;;
  duplicate_state) printf '%s,%s,%s\n' "$DOMAIN" "$CONTAINER_ID" "$TOKEN" >>"$BACKEND_IDENTITY_FILE" ;;
  invalid_state) printf '%s,bad-id,%s\n' "$DOMAIN" "$TOKEN" >>"$BACKEND_IDENTITY_FILE" ;;
  esac
  cp -R "$CONFIG_DIR" "$FIXTURE/config.before"
  cp -R "$DOCKER_MOCK_RUNTIME_DIR" "$FIXTURE/docker.before"
  : >"$DOCKER_MOCK_LOG_FILE"
}

function assert_untouched() {
  diff -r "$FIXTURE/config.before" "$CONFIG_DIR" >/dev/null || fail "$1 changed persisted state or routing"
  diff -r "$FIXTURE/docker.before" "$DOCKER_MOCK_RUNTIME_DIR" >/dev/null || fail "$1 changed a container or its network"
  if grep -Eq '^subcommand=(run|start|stop|restart|rm|rename|network (create|connect|disconnect|rm)) ' "$DOCKER_MOCK_LOG_FILE"; then
    fail "$1 issued a runtime mutation before ownership was proved"
  fi
}

function assert_backend_status() {
  local expected="$1" actual=""
  LIST_BACKENDS_INCLUDE_STATE=true list_backends >"$FIXTURE/status" || fail 'backend status listing failed'
  actual="$(awk -F '|' -v domain="$DOMAIN" '{
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
    if ($1 == domain) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
    }
  }' "$FIXTURE/status")"
  [ "$actual" = "$expected" ] || fail "expected backend status $expected, got $actual"
  if grep -Eq '^subcommand=inspect .* backend-' "$DOCKER_MOCK_LOG_FILE"; then
    fail 'status resolved runtime metadata by mutable backend name'
  fi
}

for CASE in unowned wrong_token wrong_domain wrong_root wrong_role wrong_managed stale_id missing_state duplicate_state invalid_state; do
  prepare_case "$CASE"
  for operation in snapshot refresh_ips refresh_networks start stop restart update_network remove; do
    if (
      case "$operation" in
      snapshot) _backend_container_snapshot "$DOMAIN" ;;
      refresh_ips) refresh_backend_ips ;;
      refresh_networks) refresh_backend_networks ;;
      start) start_backend "$DOMAIN" ;;
      stop) stop_backend "$DOMAIN" ;;
      restart) restart_backend "$DOMAIN" ;;
      update_network) update_backend "$DOMAIN" --network changed-net ;;
      remove) remove_backend --yes "$DOMAIN" ;;
      esac
    ) >"$FIXTURE/output" 2>&1; then
      cat "$FIXTURE/output" >&2
      fail "$operation accepted unverified ownership"
    fi
    assert_untouched "$operation"
  done
  if [ "$CASE" = stale_id ]; then
    assert_backend_status missing
  else
    assert_backend_status unverified
  fi
  assert_untouched 'status listing'
  printf '[PASS] backend ownership rejects %s before changes\n' "$CASE"
done

prepare_case managed
_backend_container_snapshot "$DOMAIN" || fail 'valid managed snapshot rejected'
[ "$BACKEND_CONTAINER_ID" = "$CONTAINER_ID" ] || fail 'snapshot returned a different ID'
[ "$(_backend_snapshot_network_ip foreign-net)" = 172.30.0.2 ] || fail 'verified network snapshot missing'
[ "$(grep -c '^subcommand=inspect ' "$DOCKER_MOCK_LOG_FILE")" -eq 1 ] || fail 'ownership/data were read in separate snapshots'
if grep -Eq '^subcommand=inspect .* backend-' "$DOCKER_MOCK_LOG_FILE"; then fail 'snapshot selected a backend by name'; fi
assert_backend_status running
grep -Fxq "subcommand=inspect -f {{.Config.Image}}|{{.Image}} $CONTAINER_ID" "$DOCKER_MOCK_LOG_FILE" || fail 'verified running-image status did not inspect the full immutable ID'
assert_untouched 'verified status listing'
for operation in start stop restart; do
  "${operation}_backend" "$DOMAIN" >/dev/null
  grep -Fxq "subcommand=$operation $CONTAINER_ID" "$DOCKER_MOCK_LOG_FILE" || fail "$operation did not use the verified full ID"
done
printf '[PASS] managed backend snapshot and lifecycle use immutable identity\n'

# The stale-ID mock must also fail a raw network lookup; inventing metadata for
# missing IDs could conceal a production regression in the ownership resolver.
if docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(printf '%064d' 1)" >/dev/null 2>&1; then
  fail 'Docker mock fabricated network metadata for an absent full ID'
fi
printf '[PASS] Docker mock rejects metadata lookup for an absent immutable ID\n'

prepare_case managed
docker rm -f "$CONTAINER_ID" >/dev/null
_cleanup_status=0
_backend_cleanup_snapshot "$DOMAIN" || _cleanup_status=$?
[ "$_cleanup_status" -eq 0 ] || fail 'cleanup rejected a proven absent container with an unoccupied canonical name'
[ -z "$BACKEND_CONTAINER_ID" ] || fail 'absent cleanup retained a runtime deletion target'
printf '[PASS] cleanup allows orphaned state only after ID and name absence are proved\n'

# Docker's name filter is a regular expression; dots can also select a sibling
# name. Only exact returned names may block cleanup of the absent canonical ID.
CASE=regex_sibling
SIBLING_NAME=backend-identityXtest
SIBLING_ID="$(command docker run -d --name "$SIBLING_NAME" --network foreign-net nginx:alpine)"
function docker() {
  if [ "${1:-}" = ps ] && [[ "$*" == *"name=^/$CNAME$"* ]]; then
    case "$*" in *'{{.Names}}'*) printf '%s\n' "$SIBLING_NAME" ;; *) printf '%s\n' "$SIBLING_ID" ;; esac
    return 0
  fi
  command docker "$@"
}
_backend_cleanup_snapshot "$DOMAIN" || fail 'regex-similar sibling name blocked cleanup of absent exact name'
[ -z "$BACKEND_CONTAINER_ID" ] || fail 'sibling name became a runtime deletion target'
unset -f docker
printf '[PASS] cleanup name collision checks compare exact names\n'

# macOS TMPDIR uses /var aliases whose physical root is /private/var. Create
# ownership using a supported physical root, then test only literal snapshot
# and fixture-label resolution through an alias. Arbitrary aliases must still
# be rejected by the state-write guard.
prepare_case managed
physical_state="$STATE_DIR"
expected_physical="$(cd "$physical_state" && pwd -P)"
ln -s "$physical_state" "$FIXTURE/logical-state"
STATE_DIR="$FIXTURE/logical-state//"
_backend_identity_inspect "$DOMAIN" "$CONTAINER_ID" "$TOKEN" || fail 'symlink-backed state root failed physical ownership proof'
physical_label="$(docker inspect -f '{{index .Config.Labels "com.dockistrate.state-dir"}}' "$CONTAINER_ID")"
[ "$physical_label" = "$expected_physical" ] || fail 'owned fixture stored the logical rather than physical state-root label'
[ "$physical_label" != "$STATE_DIR" ] || fail 'symlink regression did not exercise distinct logical and physical paths'
# shellcheck source=tests/lib/backend_identity_fixture.sh
source "$ROOT_DIR/tests/lib/backend_identity_fixture.sh"
backend_fixture_seed_labels "$FIXTURE/alias.labels" "$TOKEN" "$DOMAIN" "$STATE_DIR"
grep -Fxq "com.dockistrate.state-dir=$expected_physical" "$FIXTURE/alias.labels" || fail 'shared fixture seed retained a logical state-root label'
if _runtime_state_root_prefix_guard "$STATE_DIR" >"$FIXTURE/alias-guard.log" 2>&1; then
  fail 'arbitrary state-root alias bypassed the runtime path guard'
fi
grep -Fq 'symlinked runtime path component' "$FIXTURE/alias-guard.log" || fail 'state-root alias failed for an unexpected reason'
STATE_DIR="$physical_state"
printf '[PASS] fixture ownership resolves symlink-backed state roots literally\n'
printf '%s\n' 'Backend container identity checks passed.'
