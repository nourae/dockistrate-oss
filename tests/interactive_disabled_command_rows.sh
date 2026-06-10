#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/format_command_display.sh
source "$ROOT_DIR/lib/cli/format_command_display.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/cmd_requires_existing_backend.sh
source "$ROOT_DIR/lib/cli/cmd_requires_existing_backend.sh"
# shellcheck source=../lib/cli/has_backends.sh
source "$ROOT_DIR/lib/cli/has_backends.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/interactive_no_state.sh
source "$ROOT_DIR/lib/cli/interactive_no_state.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/choose_command_with_filter.sh
source "$ROOT_DIR/lib/cli/choose_command_with_filter.sh"
# shellcheck source=../lib/cli/interactive_picker.sh
source "$ROOT_DIR/lib/cli/interactive_picker.sh"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-disabled-rows.XXXXXX")"
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
DOCKISTRATE_NO_CLEAR=true
COLUMNS=200
SELECTED_CMD=""
SELECTED_ARGS=()
PROMPT_ARGS_COLLECTED=()
KEY_QUEUE=()
KEY_CURSOR=0
CHOICE_QUEUE=()
CHOICE_CURSOR=0
PROMPTED_CMD=""

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function queue_keys() {
  KEY_QUEUE=("$@")
  KEY_CURSOR=0
}

function cli_read_keypress() {
  local __out_var="${1:-}"
  if [ "$KEY_CURSOR" -ge "${#KEY_QUEUE[@]}" ]; then
    printf -v "$__out_var" '%s' ""
    return 0
  fi
  printf -v "$__out_var" '%s' "${KEY_QUEUE[$KEY_CURSOR]}"
  KEY_CURSOR=$((KEY_CURSOR + 1))
  return 0
}

function choose_option() {
  local __idx_var="${1:-}"
  shift 2 || true

  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    fail "choose_option queue exhausted"
  fi
  printf -v "$__idx_var" '%s' "${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  return 0
}

function prompt_args_for_command() {
  PROMPTED_CMD="${1:-}"
  SELECTED_CMD="${1:-}"
  SELECTED_ARGS=("ok")
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
  rm -rf "$CERTS_DIR" "$BACKUP_DIR"
  mkdir -p "$CERTS_DIR" "$BACKUP_DIR"
  INTERACTIVE_COMMAND_UNAVAILABLE_KIND=""
  INTERACTIVE_NO_STATE_ACTION=""
  SELECTED_CMD=""
  SELECTED_ARGS=()
  PROMPTED_CMD=""
  KEY_QUEUE=()
  KEY_CURSOR=0
  CHOICE_QUEUE=()
  CHOICE_CURSOR=0
}

function add_backend_row() {
  state_backend_ports_row_backend "example.com" "example-web" "dockistrate-net" >>"$BACKEND_PORTS_FILE"
}

function render_command_list() {
  local output_file="${1:-}" expected_cmd="${2:-}" filter="${3:-}"
  shift 3 || true
  local choice="" local_filter="$filter"
  queue_keys ""
  choose_command_with_filter choice local_filter "Choose command:" "$@" >"$output_file"
  if [ "$choice" != "$expected_cmd" ]; then
    fail "choose_command_with_filter selected '${choice}', expected '${expected_cmd}'"
  fi
}

function assert_render_contains() {
  local cmd="${1:-}" expected="${2:-}" output_file=""
  output_file="${tmp_dir}/${cmd}.out"
  shift 2 || true
  render_command_list "$output_file" "$cmd" "" "$cmd" "$@"
  if ! grep -Fq "$expected" "$output_file"; then
    fail "${cmd} output missing '${expected}'"
  fi
}

for fn in \
  interactive_command_unavailable_label \
  interactive_command_display_suffix \
  interactive_command_is_soft_unavailable \
  interactive_command_display_suffix_cache_begin \
  interactive_command_display_suffix_cache_end; do
  declare -F "$fn" >/dev/null 2>&1 || fail "missing function ${fn}"
done

reset_state_files
assert_render_contains "remove-backend" "unavailable: no backends"

reset_state_files
add_backend_row
assert_render_contains "remove-port" "unavailable: no port mappings"

reset_state_files
add_backend_row
assert_render_contains "disable-backend-mtls" "unavailable: no mTLS-enabled backends"

reset_state_files
assert_render_contains "remove-acl" "unavailable: no ACL rules"
assert_render_contains "remove-security-rule" "unavailable: no security rules"

reset_state_files
restore_output="${tmp_dir}/restore.out"
render_command_list "$restore_output" "restore-backup" "" "restore-backup"
if ! grep -Fq "no local backups; manual path allowed" "$restore_output"; then
  fail "restore-backup should advertise manual path fallback"
fi
if grep -Fq "unavailable:" "$restore_output"; then
  fail "restore-backup should not be shown as fully unavailable when a manual path is allowed"
fi

reset_state_files
add_backend_row
search_output="${tmp_dir}/search-description.out"
render_command_list "$search_output" "remove-port" "port mapping for a backend" "remove-port"
if ! grep -Fq "unavailable: no port mappings" "$search_output"; then
  fail "search result should preserve the unavailable suffix"
fi

reset_state_files
local_cache_output="${tmp_dir}/local-cache.out"
render_command_list "$local_cache_output" "add-backend" "" "add-backend"
global_cache_output="${tmp_dir}/global-cache.out"
global_cache_choice=""
global_cache_filter="add backend"
queue_keys ""
choose_global_command_with_filter global_cache_choice global_cache_filter "Search all commands:" >"$global_cache_output"
if [ "$global_cache_choice" != "add-backend" ]; then
  fail "global search selected '${global_cache_choice}', expected add-backend"
fi
if ! grep -Fq "Backends :: Add Backend" "$global_cache_output"; then
  fail "global search should keep category context after a category-menu render"
fi

reset_state_files
global_output="${tmp_dir}/global-search.out"
global_choice=""
global_filter="manual path allowed"
queue_keys ""
choose_global_command_with_filter global_choice global_filter "Search all commands:" >"$global_output"
if [ "$global_choice" != "restore-backup" ]; then
  fail "global search selected '${global_choice}', expected restore-backup"
fi
if ! grep -Fq "Backups & Restore :: Restore Backup" "$global_output"; then
  fail "global search should keep category context for restore-backup"
fi
if ! grep -Fq "manual path allowed" "$global_output"; then
  fail "global search should include the soft-unavailable restore-backup suffix"
fi

reset_state_files
CHOICE_QUEUE=(0)
queue_keys ""
if ! interactive_picker_choose_command_list "Backends:" "remove-backend" >/dev/null; then
  fail "selecting unavailable remove-backend should route through no-state guidance"
fi
if [ "$PROMPTED_CMD" != "add-backend" ] || [ "$SELECTED_CMD" != "add-backend" ]; then
  fail "unavailable command selection prompted '${PROMPTED_CMD}', expected add-backend"
fi

HAS_BACKENDS_CALLS_FILE="${tmp_dir}/has-backends.calls"
: >"$HAS_BACKENDS_CALLS_FILE"
function has_backends() {
  printf 'x\n' >>"$HAS_BACKENDS_CALLS_FILE"
  return 1
}

reset_state_files
cached_global_output="${tmp_dir}/cached-global.out"
cached_global_choice=""
cached_global_filter="remove backend"
queue_keys ""
choose_global_command_with_filter cached_global_choice cached_global_filter "Search all commands:" >"$cached_global_output"
if [ "$cached_global_choice" != "remove-backend" ]; then
  fail "cached global search selected '${cached_global_choice}', expected remove-backend"
fi
HAS_BACKENDS_CALLS="$(wc -l <"$HAS_BACKENDS_CALLS_FILE" | tr -d '[:space:]')"
if [ "$HAS_BACKENDS_CALLS" -ne 1 ]; then
  fail "global command build should cache backend availability checks, got ${HAS_BACKENDS_CALLS} has_backends calls"
fi

echo "[tests] interactive_disabled_command_rows.sh: PASS"
