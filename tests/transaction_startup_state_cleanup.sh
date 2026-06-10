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
source "$ROOT_DIR/lib/mtls.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_txn_start_cleanup.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
ORIG_ROLLBACK_TARGETS_SIGNATURE_DEF="$(declare -f _rollback_targets_signature)"
ORIG_BACKUP_FILES_ONLY_DEF="$(declare -f backup_files_only)"

function reset_test_env() {
  BASE_DIR="$TMP_ROOT/$1"
  STATE_DIR="$BASE_DIR/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CERTS_DIR="$STATE_DIR/certs"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
  BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$CERTS_DIR/mtls"
  printf 'seed\n' >"$CONFIG_DIR/state.txt"
}

function assert_transaction_state_cleared() {
  local label="${1:-transaction startup failure}"
  if [ -n "${ROLLBACK_DESC:-}" ]; then
    echo "[Error] ${label} left ROLLBACK_DESC set." >&2
    exit 1
  fi
  if [ -n "${PRE_CHANGE_BACKUP:-}" ]; then
    echo "[Error] ${label} left PRE_CHANGE_BACKUP set." >&2
    exit 1
  fi
  if [ -n "${TRANSACTION_DEPTH:-}" ]; then
    echo "[Error] ${label} left TRANSACTION_DEPTH set." >&2
    exit 1
  fi
  if [ -n "${TRANSACTION_OWNER_PID:-}" ]; then
    echo "[Error] ${label} left TRANSACTION_OWNER_PID set." >&2
    exit 1
  fi
  if [ -n "${TRANSACTION_LOCK_HELD:-}" ]; then
    echo "[Error] ${label} left TRANSACTION_LOCK_HELD set." >&2
    exit 1
  fi
  if [ -e "$(_transaction_lock_dir)" ] || [ -L "$(_transaction_lock_dir)" ]; then
    echo "[Error] ${label} left the transaction lock on disk." >&2
    exit 1
  fi
}

reset_test_env signature_failure
(
  function _rollback_targets_signature() { return 1; }

  set +e
  output="$(begin_transaction "signature_failure" "$CONFIG_DIR" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "[Error] Expected begin_transaction to fail when rollback target signature generation fails." >&2
    exit 1
  fi
  if ! grep -Fq "Failed to compute rollback target signature" <<<"$output"; then
    echo "[Error] Expected rollback target signature failure output." >&2
    exit 1
  fi
  assert_transaction_state_cleared "signature failure"
  eval "$ORIG_ROLLBACK_TARGETS_SIGNATURE_DEF"

  if ! begin_transaction "signature_retry" "$CONFIG_DIR"; then
    echo "[Error] Expected begin_transaction retry to succeed after signature failure cleanup." >&2
    exit 1
  fi
  end_transaction_success
)

reset_test_env backup_failure
(
  function backup_files_only() { return 1; }

  set +e
  output="$(begin_transaction "backup_failure" "$CONFIG_DIR" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "[Error] Expected begin_transaction to fail when pre-change backup creation fails." >&2
    exit 1
  fi
  if ! grep -Fq "Failed to create pre-change backup" <<<"$output"; then
    echo "[Error] Expected pre-change backup failure output." >&2
    exit 1
  fi
  assert_transaction_state_cleared "backup failure"
  eval "$ORIG_BACKUP_FILES_ONLY_DEF"

  if ! begin_transaction "backup_retry" "$CONFIG_DIR"; then
    echo "[Error] Expected begin_transaction retry to succeed after backup failure cleanup." >&2
    exit 1
  fi
  end_transaction_success
)

reset_test_env mtls_wrapper
(
  local_started="false"
  ROLLBACK_DESC="stale_txn"
  TRANSACTION_DEPTH=1
  TRANSACTION_OWNER_PID="999999"
  TRANSACTION_LOCK_HELD="true"

  if ! _mtls_begin_transaction_if_needed local_started "mtls_retry" "$CERTS_DIR/mtls/example.com"; then
    echo "[Error] Expected _mtls_begin_transaction_if_needed to recover from stale transaction globals." >&2
    exit 1
  fi
  if [ "$local_started" != "true" ]; then
    echo "[Error] Expected _mtls_begin_transaction_if_needed to start a real transaction after stale globals." >&2
    exit 1
  fi
  if [ "${TRANSACTION_OWNER_PID:-}" != "$$" ]; then
    echo "[Error] Expected _mtls_begin_transaction_if_needed to establish the current shell as transaction owner." >&2
    exit 1
  fi
  if [ -z "${ROLLBACK_DESC:-}" ] || [ "${ROLLBACK_DESC}" != "mtls_retry" ]; then
    echo "[Error] Expected stale rollback description to be replaced by the new transaction." >&2
    exit 1
  fi
  end_transaction_success
)

printf 'Transaction startup cleanup checks passed.\n'
