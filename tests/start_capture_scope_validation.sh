#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source real validators and CSV parsing; only runtime operations are mocked.
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck source=../lib/backends/runtime_rollback.sh
source "$ROOT_DIR/lib/backends/runtime_rollback.sh"
# shellcheck source=../lib/backends/identity.sh
source "$ROOT_DIR/lib/backends/identity.sh"
# shellcheck source=../lib/capture/common.sh
source "$ROOT_DIR/lib/capture/common.sh"
# shellcheck source=../lib/capture/filter_helpers.sh
source "$ROOT_DIR/lib/capture/filter_helpers.sh"
# A source override supports a negative control against the vulnerable version.
# shellcheck source=../lib/capture/start_capture.sh
source "${CAPTURE_START_SOURCE:-$ROOT_DIR/lib/capture/start_capture.sh}"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_capture_scope.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
# Match the physical output paths used by capture, including macOS /var aliases.
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
BASE_DIR="$TEST_ROOT"
STATE_DIR="$TEST_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
TMP_DIR="$STATE_DIR/tmp"
CAPTURE_DIR="$STATE_DIR/pcaps"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
CAPTURE_IMAGE="capture:test"
NGINX_IMAGE="nginx:test"
NGINX_CONTAINER_NAME="nginx-proxy"
SKIP_DOCKER_CHECKS=false
INTERACTIVE=false
CASE_COUNT=0
CASE_LABEL=""
RUN_ARGV="$TEST_ROOT/run.argv"
MUTATIONS="$TEST_ROOT/mutations"
OUTPUT="$TEST_ROOT/output"
INPUT_FILE="$TEST_ROOT/input"
MOCK_RUN_STATUS=0
MOCK_INSPECT_STATUS=0
SCOPE_CHOICE=0
CHOICE_STATUS=0
MOCK_API_IP="172.18.0.2"
MOCK_OTHER_IP="172.18.0.3"
MOCK_BACKEND_RUNNING=true
API_CONTAINER_ID="$(printf '%064d' 1)"
OTHER_CONTAINER_ID="$(printf '%064d' 2)"
CAPTURE_CONTAINER_ID="$(printf '%064d' 4)"
BACKEND_OWNER_TOKEN="$(printf '%032d' 3)"

function fail() {
  printf '[Error] %s: %s\n' "$CASE_LABEL" "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  exit 1
}
function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function require_managed_nginx_container() { return 0; }
function container_running() {
  [ "$1" = "$NGINX_CONTAINER_NAME" ] || [ "$MOCK_BACKEND_RUNNING" = true ]
}
function acknowledge_tls_decrypt_capture() { printf '%s\n' acknowledge >>"$MUTATIONS"; }
function enable_capture_tls_decrypt() {
  printf '%s\n' enable >>"$MUTATIONS"
  printf '%s\n' replaced >"$CAPTURE_TLS_STATE_FILE"
}
function disable_capture_tls_decrypt() { printf '%s\n' disable >>"$MUTATIONS"; }
function capture_tls_keylog_file() { return 1; }
function recreate_nginx_container() { printf '%s\n' recreate >>"$MUTATIONS"; }
# This suite isolates scope validation from the TLS launch transaction, which
# is exercised with real snapshots in start_capture_tls_launch_rollback.sh.
function _capture_tls_launch_preflight() { :; }
function _capture_tls_launch_begin() {
  CAPTURE_TLS_LAUNCH_ACTIVE=false
  enable_capture_tls_decrypt "$1"
  recreate_nginx_container
}
function _capture_tls_launch_abort() { :; }
function _capture_tls_launch_finish() { :; }
function remove_container_and_anonymous_volumes() {
  [ "$1" = "$CAPTURE_CONTAINER_ID" ] || fail 'capture cleanup did not use its immutable ID'
  printf 'remove %s\n' "$*" >>"$MUTATIONS"
  DOCKER_MOCK_RUNTIME_DIR="$TEST_ROOT/docker" "$ROOT_DIR/tests/mocks/docker" rm -f -v "$1"
}
function date() { printf '%s\n' 20260101_010203; }
function docker() {
  case "${1:-}" in
  inspect)
    [ "$MOCK_INSPECT_STATUS" -eq 0 ] || return "$MOCK_INSPECT_STATUS"
    local fixture_ips="" fixture_status=exited fixture_networks="" fixture_map="" fixture_ip="" fixture_index=0
    case "${@: -1}" in
    "$API_CONTAINER_ID") fixture_ips="$MOCK_API_IP" ;;
    "$OTHER_CONTAINER_ID") fixture_ips="$MOCK_OTHER_IP" ;;
    *) return 1 ;;
    esac
    [ "$MOCK_BACKEND_RUNNING" != true ] || fixture_status=running
    while IFS= read -r fixture_ip || [ -n "$fixture_ip" ]; do
      fixture_index=$((fixture_index + 1))
      fixture_networks+="network-${fixture_index}"$'\n'
      fixture_map+="network-${fixture_index}=${fixture_ip},"
    done <<<"$fixture_ips"
    DOCKER_MOCK_RUNTIME_DIR="$TEST_ROOT/docker" \
      DOCKER_MOCK_INSPECT_STATUS="$fixture_status" \
      DOCKER_MOCK_INSPECT_NETWORK_NAMES="$fixture_networks" \
      DOCKER_MOCK_INSPECT_NETWORK_MAP="$fixture_map" \
      "$ROOT_DIR/tests/mocks/docker" "$@"
    ;;
  ps)
    DOCKER_MOCK_RUNTIME_DIR="$TEST_ROOT/docker" "$ROOT_DIR/tests/mocks/docker" "$@"
    ;;
  run)
    printf '%s\0' "$@" >"$RUN_ARGV"
    printf '%s\n' run >>"$MUTATIONS"
    printf '%s\n' capture-container
    return "$MOCK_RUN_STATUS"
    ;;
  *) fail "unexpected Docker operation: $*" ;;
  esac
}
function choose_option() {
  printf -v "$1" '%s' "$SCOPE_CHOICE"
  return "$CHOICE_STATUS"
}
function reset_case() {
  CASE_LABEL="$1"
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  printf '%s\n' original-tls-state >"$CAPTURE_TLS_STATE_FILE"
  rm -f "$RUN_ARGV"
  : >"$MUTATIONS"
  : >"$OUTPUT"
  INTERACTIVE=false
  : >"$INPUT_FILE"
  MOCK_RUN_STATUS=0
  MOCK_INSPECT_STATUS=0
  SCOPE_CHOICE=0
  CHOICE_STATUS=0
  MOCK_API_IP="172.18.0.2"
  MOCK_OTHER_IP="172.18.0.3"
  MOCK_BACKEND_RUNNING=true
  seed_backend_identities
}
function seed_backend_identities() {
  local domain="" fixture_id=""
  rm -rf "$TEST_ROOT/docker"
  mkdir -p "$TEST_ROOT/docker"
  # Every scope case retains an existing capture until validation succeeds.
  printf 'id=%s\nstatus=running\nimage=capture:test\n' "$CAPTURE_CONTAINER_ID" >"$TEST_ROOT/docker/nginx-capture.meta"
  printf 'domain,container_id,ownership_token\n' >"$BACKEND_IDENTITY_FILE"
  for domain in api.example.test other.example.test; do
    fixture_id="$API_CONTAINER_ID"
    [ "$domain" != other.example.test ] || fixture_id="$OTHER_CONTAINER_ID"
    printf '%s,%s,%s\n' "$domain" "$fixture_id" "$BACKEND_OWNER_TOKEN" >>"$BACKEND_IDENTITY_FILE"
    {
      printf 'id=%s\nstatus=running\nimage=nginx:alpine\nnetworks=network\n' "$fixture_id"
      printf 'labels=com.dockistrate.managed=true,com.dockistrate.role=backend,com.dockistrate.state-dir=%s,com.dockistrate.backend-domain=%s,com.dockistrate.backend-launch=%s\n' "$STATE_DIR" "$domain" "$BACKEND_OWNER_TOKEN"
    } >"$TEST_ROOT/docker/backend-${domain}.meta"
  done
}
function seed_backends() {
  {
    state_backend_ports_row_backend api.example.test backend-api.example.test:8080 network
    state_backend_ports_row_port api.example.test 8443 8080 https none
    state_backend_ports_row_backend other.example.test backend-other.example.test:9090 network
    state_backend_ports_row_port other.example.test 9443 9090 https none
  } >>"$BACKEND_PORTS_FILE"
}
function expect_rejected() {
  local status=0
  local backend_state_present=false
  if [ -e "$BACKEND_PORTS_FILE" ]; then
    backend_state_present=true
    cp "$BACKEND_PORTS_FILE" "$TEST_ROOT/backend-state-before"
  fi
  start_capture "$@" <"$INPUT_FILE" >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail 'invalid request succeeded'
  if [ "$backend_state_present" = true ]; then
    cmp -s "$BACKEND_PORTS_FILE" "$TEST_ROOT/backend-state-before" || fail 'rejection changed backend state'
  else
    [ ! -e "$BACKEND_PORTS_FILE" ] || fail 'rejection created backend state'
  fi
  [ ! -e "$RUN_ARGV" ] || fail 'invalid request started a capture container'
  [ ! -s "$MUTATIONS" ] || fail 'invalid request mutated capture, TLS, or proxy state'
  [ ! -e "$CAPTURE_DIR" ] || fail 'invalid request created the capture directory'
  [ "$(cat "$CAPTURE_TLS_STATE_FILE")" = original-tls-state ] || fail 'existing TLS state changed'
  if grep -Fq 'unbound variable' "$OUTPUT"; then
    fail 'invalid request crashed instead of rejecting its scope'
  fi
  CASE_COUNT=$((CASE_COUNT + 1))
}
function expect_started() {
  start_capture "$@" <"$INPUT_FILE" >"$OUTPUT" 2>&1 || fail 'valid request failed'
  [ -s "$RUN_ARGV" ] || fail 'valid request did not start capture'
  grep -Fq 'Packet capture started' "$OUTPUT" || fail 'missing capture result'
  CASE_COUNT=$((CASE_COUNT + 1))
}
function expect_filter() {
  local folder="$1"
  shift
  printf '%s\0' run -d --name nginx-capture --net=container:nginx-proxy \
    -v "$CAPTURE_DIR/$folder:/pcaps" "$CAPTURE_IMAGE" \
    tcpdump -U -i any -s0 -w /pcaps/20260101_010203_nginx.pcap "$@" >"$TEST_ROOT/expected.argv"
  cmp -s "$TEST_ROOT/expected.argv" "$RUN_ARGV" || fail 'Docker/tcpdump argv did not preserve the exact requested filter'
}

# Parser failures must precede all capture and TLS side effects, including when
# TLS decrypt was explicitly requested before an incomplete option.
for flag in --scope --backends --clients --folder; do
  reset_case "missing value for $flag"
  expect_rejected --tls-decrypt "$flag"
  reset_case "next option is not a value for $flag"
  expect_rejected "$flag" --tls-decrypt
  reset_case "empty value for $flag"
  expect_rejected --tls-decrypt "$flag" ''
done
for scope in typo client-backendz '*' ' ' $'clients\nall'; do
  reset_case "invalid scope $scope"
  expect_rejected --tls-decrypt --scope "$scope"
done
for flag in --client --backend --scop -x --scope=clients --tls-decrypt=true; do
  reset_case "unknown flag $flag"
  expect_rejected --tls-decrypt "$flag"
done
reset_case 'unexpected second positional folder'
expect_rejected first second --tls-decrypt
reset_case 'unexpected positional arguments after terminator'
expect_rejected --tls-decrypt -- first second
reset_case 'terminator does not silently discard options'
expect_rejected --tls-decrypt -- first --scope all
for scope in all backends; do
  reset_case "client filter contradicts $scope"
  seed_backends
  expect_rejected --tls-decrypt --scope "$scope" --clients 198.51.100.10
done
for scope in all clients; do
  reset_case "backend filter contradicts $scope"
  seed_backends
  expect_rejected --tls-decrypt --scope "$scope" --backends api.example.test --clients 198.51.100.10
done

for clients in '' ' ' ',,,' '198.51.100.10 or port 22' '999.1.2.3' '198.51.100.10/24' '::1' '*' '198.51.100.10,invalid'; do
  reset_case "invalid client selection $clients"
  expect_rejected --tls-decrypt --scope clients --clients "$clients"
done
reset_case 'client scope requires a list'
expect_rejected --tls-decrypt --scope clients
for backends in '' ' ' ',,,' missing.example.test 'api.example.test missing.example.test' '*'; do
  reset_case "invalid backend selection $backends"
  seed_backends
  expect_rejected --tls-decrypt --scope backends --backends "$backends"
done
reset_case 'no configured backends'
expect_rejected --tls-decrypt --scope backends
reset_case 'missing backend state'
rm -f "$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'zero-byte backend state remains unchanged'
: >"$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends
reset_case 'invalid backend header'
printf '%s\n' invalid-header >"$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends
reset_case 'malformed state cannot create a partial filter'
seed_backends
printf '%s\n' malformed,row >>"$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'unknown backend row type is not ignored'
seed_backends
csv_join_row typo api.example.test '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' '' >>"$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'invalid domain in persisted row is rejected'
seed_backends
state_backend_ports_row_port 'invalid domain' 8443 8080 https none >>"$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'port-only row is not a configured backend'
state_backend_ports_row_port api.example.test 8443 8080 https none >>"$BACKEND_PORTS_FILE"
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'configured backend without usable capture terms'
state_backend_ports_row_backend api.example.test backend-api.example.test network >>"$BACKEND_PORTS_FILE"
MOCK_BACKEND_RUNNING=false
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'one resolvable and one unresolvable backend'
seed_backends
state_backend_ports_row_backend empty.example.test empty network >>"$BACKEND_PORTS_FILE"
MOCK_BACKEND_RUNNING=false
expect_rejected --tls-decrypt --scope backends --backends 'api.example.test empty.example.test'
reset_case 'all configured backends must resolve'
seed_backends
state_backend_ports_row_backend empty.example.test empty network >>"$BACKEND_PORTS_FILE"
MOCK_BACKEND_RUNNING=false
expect_rejected --tls-decrypt --scope backends
for port in 0 65536 '8080)'; do
  reset_case "invalid persisted upstream port $port"
  state_backend_ports_row_backend api.example.test "backend-api.example.test:$port" network >>"$BACKEND_PORTS_FILE"
  MOCK_BACKEND_RUNNING=false
  expect_rejected --tls-decrypt --scope backends --backends api.example.test
done
for ips in '172.18.0.299' '172.18.0.2 or port 22' '172.18.0.2172.19.0.2'; do
  reset_case "invalid Docker network address $ips"
  seed_backends
  MOCK_API_IP="$ips"
  expect_rejected --tls-decrypt --scope backends --backends api.example.test
done
reset_case 'Docker inspect failure cannot produce a partial filter'
seed_backends
MOCK_INSPECT_STATUS=7
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'foreign same-name backend cannot provide capture terms'
seed_backends
sed 's/com.dockistrate.managed=true/com.dockistrate.managed=false/' "$TEST_ROOT/docker/backend-api.example.test.meta" >"$TEST_ROOT/foreign.meta"
mv "$TEST_ROOT/foreign.meta" "$TEST_ROOT/docker/backend-api.example.test.meta"
expect_rejected --tls-decrypt --scope backends --backends api.example.test
reset_case 'combined scope cannot omit clients'
seed_backends
expect_rejected --tls-decrypt --scope clients-backends --backends api.example.test
reset_case 'combined scope cannot lose backend side'
expect_rejected --tls-decrypt --scope clients-backends --clients 198.51.100.10
reset_case 'combined scope cannot ignore unknown backend'
seed_backends
expect_rejected --tls-decrypt --scope clients-backends --clients 198.51.100.10 --backends missing.example.test

# Intentional full capture remains valid, and recognized repeated options retain
# their established last-value-wins behavior.
reset_case 'default full capture'
expect_started pcaps/result
expect_filter result
reset_case 'explicit full capture'
expect_started --scope ALL --folder pcaps/result
expect_filter result
reset_case 'explicit folder after terminator'
expect_started --scope all -- pcaps/result
expect_filter result
reset_case 'repeated scope keeps final value'
expect_started --scope clients --scope all --folder pcaps/result
expect_filter result
reset_case 'repeated client list keeps final value'
expect_started --scope clients --clients 198.51.100.20 --clients 198.51.100.10 --folder pcaps/result
expect_filter result '(' host 198.51.100.10 ')'
reset_case 'repeated backend list keeps final value'
seed_backends
expect_started --scope backends --backends missing.example.test --backends api.example.test --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')'
for scope in clients client CLIENTS; do
  reset_case "client alias $scope"
  expect_started --scope "$scope" --clients '198.51.100.10, 198.51.100.20 198.51.100.10' --folder pcaps/result
  expect_filter result '(' host 198.51.100.10 or host 198.51.100.20 ')'
done
for scope in backends backend BACKENDS; do
  reset_case "backend alias $scope"
  seed_backends
  expect_started --scope "$scope" --backends 'API.EXAMPLE.TEST,api.example.test' --folder pcaps/result
  expect_filter result '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')'
done
for scope in clients-backends clients_backends clientsandbackends clients-and-backends client-backend client_backends CLIENTS-BACKENDS; do
  reset_case "combined alias $scope"
  seed_backends
  expect_started --scope "$scope" --backends api.example.test --clients 198.51.100.10 --folder pcaps/result
  expect_filter result '(' '(' host 198.51.100.10 ')' and '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')' ')'
done
reset_case 'infer clients scope'
expect_started --clients 198.51.100.10 --folder pcaps/result
expect_filter result '(' host 198.51.100.10 ')'
reset_case 'infer backends scope'
seed_backends
expect_started --backends api.example.test --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')'
reset_case 'infer combined scope and preserve AND across every backend term'
seed_backends
expect_started --backends api.example.test --clients 198.51.100.10 --folder pcaps/result
expect_filter result '(' '(' host 198.51.100.10 ')' and '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')' ')'
if [ -n "${CAPTURE_SCOPE_EVIDENCE_DIR:-}" ]; then
  mkdir -p "$CAPTURE_SCOPE_EVIDENCE_DIR"
  cp "$RUN_ARGV" "$CAPTURE_SCOPE_EVIDENCE_DIR/combined-run.argv"
fi
reset_case 'omitted backend list selects every configured backend'
seed_backends
expect_started --scope backends --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 or port 9090 or port 9443 ')' or '(' host 172.18.0.2 or host 172.18.0.3 ')' ')'
reset_case 'running backend can resolve to several network addresses'
seed_backends
MOCK_API_IP=$'172.18.0.2\n172.19.0.2\n172.18.0.2'
expect_started --scope backends --backends api.example.test --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 or host 172.19.0.2 ')' ')'
reset_case 'stopped backend retains validated port terms'
seed_backends
MOCK_BACKEND_RUNNING=false
expect_started --scope backends --backends api.example.test --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 ')' ')'
reset_case 'legitimate path records do not widen backend terms'
seed_backends
state_backend_ports_row_path api.example.test /app headers 8443 >>"$BACKEND_PORTS_FILE"
expect_started --scope backends --backends api.example.test --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')'
reset_case 'decimal backend port canonicalization'
state_backend_ports_row_backend api.example.test backend-api.example.test:08080 network >>"$BACKEND_PORTS_FILE"
MOCK_BACKEND_RUNNING=false
expect_started --scope backends --backends api.example.test --folder pcaps/result
expect_filter result '(' '(' port 8080 ')' ')'
reset_case 'repeated comma separators retain valid client targets'
expect_started --clients ',,198.51.100.10,,,198.51.100.20,,' --folder pcaps/result
expect_filter result '(' host 198.51.100.10 or host 198.51.100.20 ')'
reset_case 'valid scoped TLS capture preserves its filter'
expect_started --tls-decrypt --clients 198.51.100.10 --folder pcaps/result
expect_filter result '(' host 198.51.100.10 ')'
[ "$(cat "$CAPTURE_TLS_STATE_FILE")" = replaced ] || fail 'valid TLS capture did not enable state'
printf '%s\n' acknowledge "remove $CAPTURE_CONTAINER_ID" enable recreate run >"$TEST_ROOT/expected-mutations"
cmp -s "$TEST_ROOT/expected-mutations" "$MUTATIONS" || fail 'valid TLS capture mutation sequence changed'
reset_case 'decimal client IP canonicalization'
expect_started --scope clients --clients 010.000.000.001 --folder pcaps/result
expect_filter result '(' host 10.0.0.1 ')'
reset_case 'separator whitespace does not expand glob patterns'
seed_backends
expect_started --scope backends --backends $'API.EXAMPLE.TEST\napi.example.test\tapi.example.test\rapi.example.test' --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')'

reset_case 'Docker capture launch failure is not reported as success'
MOCK_RUN_STATUS=42
status=0
start_capture --scope clients --clients 198.51.100.10 --folder pcaps/result <"$INPUT_FILE" >"$OUTPUT" 2>&1 || status=$?
[ "$status" -eq 42 ] || fail 'Docker launch failure status was lost'
[ -s "$RUN_ARGV" ] || fail 'Docker launch was not attempted'
if grep -Fq 'Packet capture started' "$OUTPUT"; then
  fail 'failed Docker launch reported capture success'
fi
CASE_COUNT=$((CASE_COUNT + 1))

# Interactive selection shares the same fail-closed validation and filter.
for scope in 1 3; do
  reset_case "interactive backend scope $scope with no configured backends"
  INTERACTIVE=true
  SCOPE_CHOICE="$scope"
  printf '\n' >"$INPUT_FILE"
  expect_rejected --tls-decrypt --folder pcaps/result
done
reset_case 'interactive empty clients do not become all traffic'
INTERACTIVE=true
SCOPE_CHOICE=2
printf '\n' >"$INPUT_FILE"
expect_rejected --tls-decrypt --folder pcaps/result
reset_case 'interactive unknown backend does not become all traffic'
seed_backends
INTERACTIVE=true
SCOPE_CHOICE=1
printf '%s\n' missing.example.test >"$INPUT_FILE"
expect_rejected --tls-decrypt --folder pcaps/result
reset_case 'interactive combined scope requires clients'
seed_backends
INTERACTIVE=true
SCOPE_CHOICE=3
printf '%s\n' api.example.test '' >"$INPUT_FILE"
expect_rejected --tls-decrypt --folder pcaps/result
reset_case 'interactive scope cancellation is side effect free'
INTERACTIVE=true
CHOICE_STATUS=1
expect_rejected --tls-decrypt --folder pcaps/result
# Exercise the real Bash reader: EOF with no bytes and a partial, unsubmitted
# line must cancel every prompt. A submitted blank backend line remains valid.
for choice in 0 1 2; do
  for ending in empty partial; do
    reset_case "interactive prompt $choice with $ending EOF"
    seed_backends
    INTERACTIVE=true
    SCOPE_CHOICE="$choice"
    if [ "$ending" = partial ]; then
      case "$choice" in
      0) printf y >"$INPUT_FILE" ;;
      1) printf api.example.test >"$INPUT_FILE" ;;
      2) printf 198.51.100.10 >"$INPUT_FILE" ;;
      esac
    fi
    expect_rejected --folder pcaps/result
    grep -Fq 'Packet capture cancelled' "$OUTPUT" || fail 'EOF did not report cancellation'
  done
done
reset_case 'interactive combined client prompt partial EOF'
seed_backends
INTERACTIVE=true
SCOPE_CHOICE=3
printf 'api.example.test\n198.51.100.10' >"$INPUT_FILE"
expect_rejected --folder pcaps/result
reset_case 'interactive invalid picker result'
INTERACTIVE=true
SCOPE_CHOICE=9
expect_rejected --tls-decrypt --folder pcaps/result
reset_case 'interactive explicit full capture'
INTERACTIVE=true
SCOPE_CHOICE=0
printf '%s\n' n >"$INPUT_FILE"
expect_started --folder pcaps/result
expect_filter result
reset_case 'interactive blank backend selection means all configured'
seed_backends
INTERACTIVE=true
SCOPE_CHOICE=1
printf '%s\n' '' n >"$INPUT_FILE"
expect_started --folder pcaps/result
expect_filter result '(' '(' port 8080 or port 8443 or port 9090 or port 9443 ')' or '(' host 172.18.0.2 or host 172.18.0.3 ')' ')'
reset_case 'interactive combined scope preserves both restrictions'
seed_backends
INTERACTIVE=true
SCOPE_CHOICE=3
printf '%s\n' api.example.test 198.51.100.10 n >"$INPUT_FILE"
expect_started --folder pcaps/result
expect_filter result '(' '(' host 198.51.100.10 ')' and '(' '(' port 8080 or port 8443 ')' or '(' host 172.18.0.2 ')' ')' ')'

printf 'start-capture scope validation: %s cases passed.\n' "$CASE_COUNT"
