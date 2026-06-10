#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/interactive_dashboard.sh
source "$ROOT_DIR/lib/cli/interactive_dashboard.sh"
# shellcheck source=../lib/cli/interactive_picker.sh
source "$ROOT_DIR/lib/cli/interactive_picker.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-dashboard.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

CONFIG_DIR="${tmp_dir}/config"
CERTS_DIR="${tmp_dir}/certs"
BACKUP_DIR="${tmp_dir}/backups"
BACKEND_PORTS_FILE="${CONFIG_DIR}/backend_ports.csv"
NGINX_CONTAINER_NAME="nginx-proxy"
DOCKISTRATE_NO_CLEAR=true
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$BACKUP_DIR"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function clear() { :; }

DOCKER_PS_A_OUTPUT=""
DOCKER_PS_A_STATUS=127
DOCKER_PS_OUTPUT=""
DOCKER_PS_STATUS=127
DOCKER_INSPECT_OUTPUT=""
DOCKER_INSPECT_STATUS=127
function docker() {
  case "${1:-}" in
  ps)
    if [ "${2:-}" = "-a" ]; then
      [ "$DOCKER_PS_A_STATUS" -eq 0 ] || return "$DOCKER_PS_A_STATUS"
      printf '%s\n' "$DOCKER_PS_A_OUTPUT"
      return 0
    fi
    [ "$DOCKER_PS_STATUS" -eq 0 ] || return "$DOCKER_PS_STATUS"
    printf '%s\n' "$DOCKER_PS_OUTPUT"
    return 0
    ;;
  inspect)
    [ "$DOCKER_INSPECT_STATUS" -eq 0 ] || return "$DOCKER_INSPECT_STATUS"
    printf '%s\n' "$DOCKER_INSPECT_OUTPUT"
    return 0
    ;;
  esac
  return 127
}

function cli_read_keypress() {
  local __out_var="${1:-}"
  printf -v "$__out_var" '%s' ""
  return 1
}

function assert_contains() {
  local label="${1:-}" needle="${2:-}" haystack="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "${label}: missing '${needle}'"
  fi
}

function assert_equals() {
  local label="${1:-}" expected="${2:-}" actual="${3:-}"
  if [ "$actual" != "$expected" ]; then
    fail "${label}: expected '${expected}', got '${actual}'"
  fi
}

function reset_dashboard_state() {
  rm -rf "$CONFIG_DIR" "$CERTS_DIR" "$BACKUP_DIR"
  mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$BACKUP_DIR"
}

for fn in \
  interactive_dashboard_proxy_state \
  interactive_dashboard_backend_count \
  interactive_dashboard_port_count \
  interactive_dashboard_cert_count \
  interactive_dashboard_backup_count \
  interactive_dashboard_capture_state \
  interactive_dashboard_summary; do
  declare -F "$fn" >/dev/null 2>&1 || fail "missing function ${fn}"
done

reset_dashboard_state
summary="$(interactive_dashboard_summary)"
assert_contains "empty proxy state" "Proxy:        unknown" "$summary"
assert_contains "empty backend count" "Backends:     0 configured" "$summary"
assert_contains "empty port count" "Ports:        0 mappings" "$summary"
assert_contains "empty cert count" "Certificates: 0 cert directories" "$summary"
assert_contains "empty backup count" "Backups:      0 available" "$summary"
assert_contains "empty capture state" "Capture:      unknown" "$summary"

printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend "example.com" "example-web:8080" "dockistrate-net" >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_port "example.com" "18080" "8080" "http" "none" "no" "off" "" >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_port "example.com" "18443" "8443" "https" "custom/live/example.com" "no" "off" "" >>"$BACKEND_PORTS_FILE"
mkdir -p "$CERTS_DIR/custom/live/example.com" "$CERTS_DIR/selfsigned/live/internal.example.com"
mkdir -p "$BACKUP_DIR/20260504_000001_ManualBackup"
: >"$BACKUP_DIR/20260504_000002_ManualBackup.tar.gz"
: >"$BACKUP_DIR/last_full_backup.txt"
: >"$BACKUP_DIR/last_full_backup.sha256"

summary="$(interactive_dashboard_summary)"
assert_contains "state backend count" "Backends:     1 configured" "$summary"
assert_contains "state port count" "Ports:        2 mappings" "$summary"
assert_contains "state cert count" "Certificates: 2 cert directories" "$summary"
assert_contains "state backup count" "Backups:      2 available" "$summary"

DOCKISTRATE_RUNTIME_PREPARED=true
DOCKER_PS_A_STATUS=0
DOCKER_PS_A_OUTPUT=""
DOCKER_INSPECT_STATUS=127
assert_equals "missing proxy container" "unknown" "$(interactive_dashboard_proxy_state)"

DOCKER_PS_A_OUTPUT="nginx-proxy"
DOCKER_INSPECT_STATUS=0
DOCKER_INSPECT_OUTPUT="exited"
assert_equals "stopped proxy container" "stopped" "$(interactive_dashboard_proxy_state)"

DOCKER_INSPECT_OUTPUT="running"
assert_equals "running proxy container" "running" "$(interactive_dashboard_proxy_state)"

DOCKER_PS_STATUS=0
DOCKER_PS_OUTPUT="nginx-capture"
assert_equals "active capture container" "active" "$(interactive_dashboard_capture_state)"

DOCKER_PS_OUTPUT="nginx-proxy"
assert_equals "inactive capture container" "inactive" "$(interactive_dashboard_capture_state)"

DOCKER_PS_STATUS=127
assert_equals "unknown capture when docker fails" "unknown" "$(interactive_dashboard_capture_state)"
DOCKISTRATE_RUNTIME_PREPARED=false

reset_dashboard_state
summary="$(interactive_dashboard_summary)"
assert_contains "missing files backend count" "Backends:     0 configured" "$summary"
assert_contains "missing files port count" "Ports:        0 mappings" "$summary"

output_file="${tmp_dir}/home.out"
if interactive_picker >"$output_file"; then
  fail "EOF from the home dashboard should return non-zero"
fi
home_output="$(cat "$output_file")"
assert_contains "home dashboard proxy" "Proxy:" "$home_output"
assert_contains "home dashboard backends" "Backends:" "$home_output"
assert_contains "home dashboard prompt" "What do you want to do?" "$home_output"

echo "[tests] interactive_dashboard_summary.sh: PASS"
