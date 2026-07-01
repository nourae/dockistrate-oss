#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/logging/log_msg.sh
  source "$ROOT_DIR/lib/logging/log_msg.sh"
  log_msg "unset logging variables should not crash"
'

ROOT_DIR="$ROOT_DIR" bash -c '
  set -Eeuo pipefail
  # shellcheck source=../lib/backups/end_transaction_success.sh
  source "$ROOT_DIR/lib/backups/end_transaction_success.sh"
  function _transaction_clear_installed_traps() { :; }
  function release_transaction_lock() { :; }
  TRANSACTION_DEPTH=1
  TRANSACTION_MODE=return
  end_transaction_success
'

echo "[tests] direct_sourcing_set_u_guards.sh: PASS"
