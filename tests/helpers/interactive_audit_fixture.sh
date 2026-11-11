# shellcheck shell=bash

# A declarations-only load, followed by state confined to a private test root.
for module in config utils security_rules domain_config headers cli; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-interactive-audit.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
STATE_DIR="$TEST_ROOT/state" TMP_DIR="$TEST_ROOT/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
state_csv_ensure_all_state_files
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend primary.example.com 127.0.0.1:8080 dockistrate-net >>"$BACKEND_PORTS_FILE"
printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
  'alias,alias.example.com,primary.example.com' \
  'dedicated,dedicated.example.com,primary.example.com' >"$BACKEND_ALIASES_FILE"
INTERACTIVE=true VERBOSE=false DOCKISTRATE_NO_CLEAR=true
function fail_test() { echo "[Error] $*" >&2; exit 1; }
# Only external effects are stubbed: collection, review, dispatch and CSV writes
# use product functions. Full transaction/runtime behavior has separate tests.
function _review_domain_config_pending() { return 0; }
function _config_begin_transaction_if_needed() { :; }
function _config_end_transaction_if_started() { :; }
function create_backup() { :; }
function update_nginx_config_for_security_change() { :; }
function audit_log() { :; }
