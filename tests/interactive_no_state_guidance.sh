#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/cmd_requires_existing_backend.sh
source "$ROOT_DIR/lib/cli/cmd_requires_existing_backend.sh"
# shellcheck source=../lib/cli/has_backends.sh
source "$ROOT_DIR/lib/cli/has_backends.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/interactive_no_state.sh
source "$ROOT_DIR/lib/cli/interactive_no_state.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/interactive_picker.sh
source "$ROOT_DIR/lib/cli/interactive_picker.sh"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-no-state-guidance.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

CONFIG_DIR="${tmp_dir}/config"
CERTS_DIR="${tmp_dir}/certs"
BACKUP_DIR="${tmp_dir}/backups"
BACKEND_PORTS_FILE="${CONFIG_DIR}/backend_ports.csv"
BACKEND_HEADERS_FILE="${CONFIG_DIR}/backend_headers.csv"
BACKEND_MTLS_FILE="${CONFIG_DIR}/backend_mtls.csv"
SECURITY_IP_RULES_FILE="${CONFIG_DIR}/security_ip_rules.csv"
SECURITY_RULES_FILE="${CONFIG_DIR}/security_rules.csv"
SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
SECURITY_RULES_DB="$SECURITY_RULES_FILE"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$BACKUP_DIR"

INTERACTIVE=true
SELECTED_CMD=""
SELECTED_ARGS=()
PROMPT_ARGS_COLLECTED=()
CHOICE_QUEUE=()
CHOICE_CURSOR=0
LAST_PROMPT=""
LAST_OPTIONS=()

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function choose_option() {
  local __idx_var="${1:-}" prompt="${2:-}"
  shift 2 || true
  LAST_PROMPT="$prompt"
  LAST_OPTIONS=("$@")

  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    fail "choose_option queue exhausted"
  fi
  printf -v "$__idx_var" '%s' "${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  return 0
}

function reset_state_files() {
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  printf '%s\n' "$STATE_BACKEND_HEADERS_HEADER" >"$BACKEND_HEADERS_FILE"
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$BACKEND_MTLS_FILE"
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_FILE"
  printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$SECURITY_RULES_FILE"
  SECURITY_IP_RULES_DB="$SECURITY_IP_RULES_FILE"
  SECURITY_RULES_DB="$SECURITY_RULES_FILE"
  rm -rf "$CERTS_DIR"
  rm -rf "$BACKUP_DIR"
  mkdir -p "$CERTS_DIR" "$BACKUP_DIR"
  INTERACTIVE_COMMAND_UNAVAILABLE_KIND=""
  INTERACTIVE_NO_STATE_ACTION=""
  CHOICE_QUEUE=()
  CHOICE_CURSOR=0
  LAST_PROMPT=""
  LAST_OPTIONS=()
  SELECTED_CMD=""
  SELECTED_ARGS=()
  PROMPTED_CMD=""
}

function add_backend_row() {
  state_backend_ports_row_backend "example.com" "example-web" "dockistrate-net" >>"$BACKEND_PORTS_FILE"
}

function add_http_port_row() {
  state_backend_ports_row_port "example.com" "18080" "8080" "http" "" "no" "no" "" >>"$BACKEND_PORTS_FILE"
}

function add_certificate_state() {
  mkdir -p "$CERTS_DIR/custom/live/example.com"
  : >"$CERTS_DIR/custom/live/example.com/fullchain.pem"
}

function add_partial_certificate_state() {
  mkdir -p "$CERTS_DIR/custom/live/broken.example.com"
}

function add_backup_marker_state() {
  printf '%s\n' "${BACKUP_DIR}/20260504_000000_ManualBackup.tar.gz" >"${BACKUP_DIR}/last_full_backup.txt"
  printf '%s\n' "checksum" >"${BACKUP_DIR}/last_full_backup.sha256"
}

function add_backup_dir_state() {
  mkdir -p "${BACKUP_DIR}/20260504_000001_ManualBackup/config"
}

function add_backup_archive_state() {
  : >"${BACKUP_DIR}/20260504_000002_ManualBackup.tar.gz"
}

function assert_unavailable_kind() {
  local cmd="${1:-}" expected="${2:-}"
  local status=0
  set +e
  interactive_command_availability "$cmd"
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail "${cmd} should be unavailable"
  fi
  if [ "$INTERACTIVE_COMMAND_UNAVAILABLE_KIND" != "$expected" ]; then
    fail "${cmd} unavailable kind '${INTERACTIVE_COMMAND_UNAVAILABLE_KIND}', expected '${expected}'"
  fi
}

function assert_available() {
  local cmd="${1:-}"
  if ! interactive_command_availability "$cmd"; then
    fail "${cmd} should be available, got '${INTERACTIVE_COMMAND_UNAVAILABLE_KIND}'"
  fi
}

function assert_guidance_action() {
  local cmd="${1:-}" expected_action="${2:-}" expected_text="${3:-}"
  local status=0
  CHOICE_QUEUE=(0)
  CHOICE_CURSOR=0
  set +e
  interactive_no_state_guidance "$cmd" >/dev/null
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    fail "${cmd} guidance should return 0 for setup action, got ${status}"
  fi
  if [ "$INTERACTIVE_NO_STATE_ACTION" != "$expected_action" ]; then
    fail "${cmd} guidance action '${INTERACTIVE_NO_STATE_ACTION}', expected '${expected_action}'"
  fi
  if [[ "$LAST_PROMPT" != *"$expected_text"* ]]; then
    fail "${cmd} guidance prompt missing '${expected_text}'"
  fi
  if [ "${LAST_OPTIONS[0]:-}" = "Return to previous menu" ]; then
    fail "${cmd} guidance should offer setup before returning"
  fi
}

function assert_guidance_status() {
  local cmd="${1:-}" choice="${2:-}" expected_status="${3:-}"
  local status=0
  CHOICE_QUEUE=("$choice")
  CHOICE_CURSOR=0
  set +e
  interactive_no_state_guidance "$cmd" >/dev/null
  status=$?
  set -e
  if [ "$status" -ne "$expected_status" ]; then
    fail "${cmd} guidance choice ${choice} returned ${status}, expected ${expected_status}"
  fi
}

for fn in interactive_command_availability interactive_no_state_guidance; do
  declare -F "$fn" >/dev/null 2>&1 || fail "missing function ${fn}"
done

reset_state_files
assert_unavailable_kind "remove-backend" "no_backends"
assert_guidance_action "remove-backend" "add-backend" "no backends are configured"
assert_guidance_status "remove-backend" 1 1
assert_guidance_status "remove-backend" 2 2

reset_state_files
add_backend_row
assert_available "add-port"
assert_unavailable_kind "remove-port" "no_port_mappings"
assert_guidance_action "remove-port" "add-port" "no port mappings are configured"

reset_state_files
add_backend_row
add_http_port_row
assert_available "remove-port"

reset_state_files
assert_unavailable_kind "remove-cert" "no_certs"
assert_guidance_action "remove-cert" "add-cert" "no certificates are configured"
add_partial_certificate_state
assert_available "remove-cert"
reset_state_files
add_certificate_state
assert_available "remove-cert"

reset_state_files
assert_unavailable_kind "restore-backup" "no_backups"
assert_guidance_action "restore-backup" "create-backup" "no backups are available"
assert_guidance_status "restore-backup" 1 3
add_backup_marker_state
assert_unavailable_kind "restore-backup" "no_backups"
reset_state_files
add_backup_dir_state
assert_available "restore-backup"
reset_state_files
add_backup_archive_state
assert_available "restore-backup"

reset_state_files
add_backend_row
assert_unavailable_kind "remove-backend-header" "no_backend_headers"
assert_guidance_action "remove-backend-header" "add-backend-header" "no backend headers are configured"
printf '%s\n' "example.com,response,X-Test,ok" >>"$BACKEND_HEADERS_FILE"
assert_available "remove-backend-header"

reset_state_files
add_backend_row
assert_unavailable_kind "disable-backend-mtls" "no_mtls"
assert_guidance_action "disable-backend-mtls" "enable-backend-mtls" "none are configured"
printf '%s\n' "example.com,example.com" >>"$BACKEND_MTLS_FILE"
assert_available "disable-backend-mtls"

reset_state_files
assert_unavailable_kind "remove-acl" "no_acl_rules"
assert_guidance_action "remove-acl" "add-acl" "no ACL rules are configured"
printf '%s\n' "yes,example.com,backend,deny,192.0.2.10,403" >>"$SECURITY_IP_RULES_FILE"
assert_available "remove-acl"

reset_state_files
SECURITY_IP_RULES_DB="${CONFIG_DIR}/security_ip_rules_override.csv"
printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_DB"
printf '%s\n' "yes,example.com,backend,deny,192.0.2.11,403" >>"$SECURITY_IP_RULES_DB"
assert_available "remove-acl"

reset_state_files
assert_unavailable_kind "remove-security-rule" "no_security_rules"
assert_guidance_action "remove-security-rule" "add-security-rule" "no security rules are configured"
printf '%s\n' "yes,example.com,all,403,1,header,X-Test,equals,bad,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,manual,test" >>"$SECURITY_RULES_FILE"
assert_available "remove-security-rule"

PROMPTED_CMD=""
function prompt_args_for_command() {
  PROMPTED_CMD="${1:-}"
  SELECTED_CMD="${1:-}"
  SELECTED_ARGS=("ok")
  return 0
}

function choose_global_command_with_filter() {
  local __cmd_var="${1:-}"
  printf -v "$__cmd_var" '%s' "remove-backend"
  return 0
}

reset_state_files
CHOICE_QUEUE=(0)
if ! interactive_picker_run_command_prompt "remove-backend" >/dev/null; then
  fail "picker should route missing backend guidance to add-backend"
fi
if [ "$PROMPTED_CMD" != "add-backend" ] || [ "$SELECTED_CMD" != "add-backend" ]; then
  fail "picker routed to '${PROMPTED_CMD}', expected add-backend"
fi

reset_state_files
CHOICE_QUEUE=(1)
set +e
interactive_picker_run_command_prompt "remove-backend" >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ] || [ -n "${SELECTED_CMD:-}" ]; then
  fail "Return to previous menu should clear selection and return 1"
fi

reset_state_files
CHOICE_QUEUE=(2)
set +e
interactive_picker_run_command_prompt "remove-backend" >/dev/null
status=$?
set -e
if [ "$status" -ne 2 ] || [ -n "${SELECTED_CMD:-}" ]; then
  fail "Quit from no-state guidance should clear selection and return 2"
fi

reset_state_files
CHOICE_QUEUE=(1)
if ! interactive_picker_run_command_prompt "restore-backup" >/dev/null; then
  fail "picker should allow restore-backup to continue to manual path prompt"
fi
if [ "$PROMPTED_CMD" != "restore-backup" ] || [ "$SELECTED_CMD" != "restore-backup" ]; then
  fail "picker prompted '${PROMPTED_CMD}', expected restore-backup"
fi

reset_state_files
INTERACTIVE=true
CHOICE_QUEUE=(0 2)
set +e
interactive_command_browser >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ] || [ -n "${SELECTED_CMD:-}" ]; then
  fail "Quit from advanced-browser global search guidance should exit the browser"
fi

reset_state_files
INTERACTIVE=false
if ! interactive_picker_run_command_prompt "remove-backend" >/dev/null; then
  fail "non-interactive prompt path should not be blocked by interactive no-state guidance"
fi
if [ "$PROMPTED_CMD" != "remove-backend" ]; then
  fail "non-interactive path prompted '${PROMPTED_CMD}', expected remove-backend"
fi

echo "[tests] interactive_no_state_guidance.sh: PASS"
