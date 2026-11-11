#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_security_rule_arity.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

STATE_DIR="$TMP_ROOT/state"
CONFIG_DIR="$STATE_DIR/config"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
SECURITY_RULES_DB="$CONFIG_DIR/security_rules.csv"
mkdir -p "$CONFIG_DIR"

function write_backend_state() {
  cat >"$BACKEND_PORTS_FILE" <<'EOF_PORTS'
record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location
backend,example.com,127.0.0.1:8080,dockistrate-net,,,,,,,,,,,,,,,,,
EOF_PORTS
}

function run_add_rule_expect_failure() {
  local output_file="${1:-}"
  shift
  set +e
  (add_security_rule "$@") >"$output_file" 2>&1
  local status=$?
  set -e
  [ "$status" -ne 0 ]
}

write_backend_state
output_file="$TMP_ROOT/surplus.out"
if ! run_add_rule_expect_failure "$output_file" example.com 1 header X-Test equals ok surplus; then
  echo "[Error] add_security_rule accepted surplus condition arguments." >&2
  exit 1
fi
if ! grep -Fq "expected exactly 4 condition args, got 5" "$output_file"; then
  echo "[Error] add_security_rule did not report its exact argument requirement." >&2
  cat "$output_file" >&2
  exit 1
fi
if [ -e "$SECURITY_RULES_DB" ]; then
  echo "[Error] add_security_rule mutated state before rejecting surplus arguments." >&2
  exit 1
fi

output_file="$TMP_ROOT/flags-only.out"
if ! run_add_rule_expect_failure "$output_file" example.com 1 --code 403; then
  echo "[Error] add_security_rule accepted a flags-only condition payload." >&2
  exit 1
fi
if ! grep -Fq "expected exactly 4 condition args, got 0" "$output_file"; then
  echo "[Error] add_security_rule did not handle flags-only arity safely." >&2
  cat "$output_file" >&2
  exit 1
fi
if grep -Fq "unbound variable" "$output_file"; then
  echo "[Error] add_security_rule hit Bash nounset while handling flags-only input." >&2
  cat "$output_file" >&2
  exit 1
fi

transaction_marker="$TMP_ROOT/transaction.started"
rollback_marker="$TMP_ROOT/transaction.rolled-back"
function _config_begin_transaction_if_needed() {
  local __started_var="${1:-}"
  printf -v "$__started_var" '%s' "true"
  : >"$transaction_marker"
}

output_file="$TMP_ROOT/invalid-condition.out"
if ! run_add_rule_expect_failure "$output_file" example.com 1 header X-Test invalid-condition ok; then
  echo "[Error] add_security_rule accepted an invalid condition." >&2
  exit 1
fi
if [ -e "$transaction_marker" ] || [ -e "$SECURITY_RULES_DB" ]; then
  echo "[Error] add_security_rule began a transaction before validating the complete rule." >&2
  exit 1
fi

function _config_begin_transaction_if_needed() {
  local __started_var="${1:-}"
  printf -v "$__started_var" '%s' "true"
  : >"$transaction_marker"
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
}

function transaction_return_failure() {
  : >"$rollback_marker"
  return 1
}

write_backend_state
rm -f "$transaction_marker" "$rollback_marker"
output_file="$TMP_ROOT/backend-race.out"
if ! run_add_rule_expect_failure "$output_file" example.com 1 header X-Test equals ok; then
  echo "[Error] add_security_rule accepted an orphan rule after its backend disappeared." >&2
  exit 1
fi
if ! grep -Fq "was removed before the security rule could be saved" "$output_file"; then
  echo "[Error] add_security_rule did not report the post-lock backend removal." >&2
  cat "$output_file" >&2
  exit 1
fi
if [ ! -e "$transaction_marker" ] || [ ! -e "$rollback_marker" ]; then
  echo "[Error] add_security_rule did not roll back the post-lock backend removal." >&2
  exit 1
fi
if [ -e "$SECURITY_RULES_DB" ]; then
  echo "[Error] add_security_rule wrote orphan state after its backend disappeared." >&2
  exit 1
fi

printf 'Security-rule additions reject invalid arity and backend-removal races before mutation.\n'
