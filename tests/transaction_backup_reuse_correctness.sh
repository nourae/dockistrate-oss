#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/config.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_txn_backup_reuse.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_equals() {
  local expected="$1" actual="$2" message="$3"
  if [ "$expected" != "$actual" ]; then
    fail_test "$message (expected '$expected', got '$actual')"
  fi
}

function assert_not_equals() {
  local left="$1" right="$2" message="$3"
  if [ "$left" = "$right" ]; then
    fail_test "$message (both were '$left')"
  fi
}

function assert_file_exists() {
  local path="$1"
  [ -f "$path" ] || fail_test "Expected file to exist: $path"
}

function reset_test_env() {
  local label="$1"
  BASE_DIR="$TMP_ROOT/$label"
  STATE_DIR="$BASE_DIR/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  BACKUP_DIR="$STATE_DIR/backups"
  CERTS_DIR="$STATE_DIR/certs"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"

  rm -rf "$BASE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$CAPTURE_DIR" \
    "$BACKUP_DIR" "$CERTS_DIR" "$ACME_WEBROOT_DIR"

  unset PRE_CHANGE_BACKUP ROLLBACK_DESC ROLLBACK_FILES ROLLBACK_NEW_FILES
  unset ROLLBACK_RESTORE_CLEAR_DIRS ROLLBACK_PRE_HOOK
  unset TRANSACTION_DEPTH TRANSACTION_OWNER_PID TRANSACTION_LOCK_HELD

  printf 'config-%s\n' "$label" >"$CONFIG_DIR/settings.txt"
}

function seed_post_backup() {
  local desc="$1"
  shift

  begin_transaction "$desc" "$@" || fail_test "Failed to start seed transaction '$desc'"
  end_transaction_success || fail_test "Failed to finish seed transaction '$desc'"
  cat "$LAST_POST_BACKUP_FILE"
}

function assert_reuses_last_post() {
  local desc="$1" expected_backup="$2"
  shift 2

  begin_transaction "$desc" "$@" || fail_test "Failed to start transaction '$desc'"
  assert_equals "$expected_backup" "$PRE_CHANGE_BACKUP" "Expected transaction '$desc' to reuse the last post backup"
  end_transaction_success || fail_test "Failed to finish transaction '$desc'"
}

function assert_creates_fresh_pre_backup() {
  local desc="$1" last_post_backup="$2"
  shift 2

  begin_transaction "$desc" "$@" || fail_test "Failed to start transaction '$desc'"
  assert_not_equals "$last_post_backup" "$PRE_CHANGE_BACKUP" "Expected transaction '$desc' to create a fresh pre-change backup"
  assert_file_exists "$PRE_CHANGE_BACKUP"
  end_transaction_success || fail_test "Failed to finish transaction '$desc'"
}

# Scenario A: unchanged rollback target state should reuse the last post backup.
reset_test_env reuse_unchanged
printf 'cert-a\n' >"$CERTS_DIR/server.pem"
last_post_backup="$(seed_post_backup seed_reuse "$CONFIG_DIR" "$CERTS_DIR")"
assert_reuses_last_post reuse_unchanged "$last_post_backup" "$CONFIG_DIR" "$CERTS_DIR"

# Scenario B: config unchanged but cert state changed should force a fresh pre backup.
reset_test_env certs_changed
printf 'cert-before\n' >"$CERTS_DIR/server.pem"
last_post_backup="$(seed_post_backup seed_certs "$CONFIG_DIR" "$CERTS_DIR")"
printf 'cert-after\n' >"$CERTS_DIR/server.pem"
assert_creates_fresh_pre_backup certs_changed "$last_post_backup" "$CONFIG_DIR" "$CERTS_DIR"

# Scenario C: config unchanged but tmp state changed should force a fresh pre backup.
reset_test_env tmp_changed
printf 'tmp-before\n' >"$TMP_DIR/runtime.txt"
last_post_backup="$(seed_post_backup seed_tmp "$CONFIG_DIR" "$TMP_DIR" "$CAPTURE_DIR")"
printf 'tmp-after\n' >"$TMP_DIR/runtime.txt"
assert_creates_fresh_pre_backup tmp_changed "$last_post_backup" "$CONFIG_DIR" "$TMP_DIR" "$CAPTURE_DIR"

# Scenario D: config unchanged but capture state changed should force a fresh pre backup.
reset_test_env capture_changed
printf 'pcap-before\n' >"$CAPTURE_DIR/session.pcap"
last_post_backup="$(seed_post_backup seed_capture "$CONFIG_DIR" "$TMP_DIR" "$CAPTURE_DIR")"
printf 'pcap-after\n' >"$CAPTURE_DIR/session.pcap"
assert_creates_fresh_pre_backup capture_changed "$last_post_backup" "$CONFIG_DIR" "$TMP_DIR" "$CAPTURE_DIR"

# Scenario E: changing the rollback target set should disable reuse even if contents are unchanged.
reset_test_env target_set_changed
printf 'cert-static\n' >"$CERTS_DIR/server.pem"
last_post_backup="$(seed_post_backup seed_target_set "$CONFIG_DIR" "$CERTS_DIR")"
assert_creates_fresh_pre_backup target_set_changed "$last_post_backup" "$CONFIG_DIR"


# Scenario E2: changed rollback targets should short-circuit before state hashing.
reset_test_env target_set_short_circuit
printf 'cert-static
' >"$CERTS_DIR/server.pem"
last_post_backup="$(seed_post_backup seed_target_short_circuit "$CONFIG_DIR" "$CERTS_DIR")"
ORIG_ROLLBACK_STATE_SIGNATURE_DEF="$(declare -f _rollback_targets_state_signature)"
(
  eval "${ORIG_ROLLBACK_STATE_SIGNATURE_DEF/_rollback_targets_state_signature/_orig_rollback_targets_state_signature}"
  function _rollback_targets_state_signature() {
    return 1
  }

  begin_transaction "target_set_short_circuit" "$CONFIG_DIR" || exit 1
  [ "$PRE_CHANGE_BACKUP" != "$last_post_backup" ] || exit 1

  eval "$ORIG_ROLLBACK_STATE_SIGNATURE_DEF"
  end_transaction_success || exit 1
) || fail_test "Expected changed rollback targets to skip state hashing and fall back to a fresh pre-change backup"

# Scenario F: non-regular entries should influence the rollback target state signature.
reset_test_env fifo_changed
last_post_backup="$(seed_post_backup seed_fifo "$CONFIG_DIR" "$TMP_DIR")"
mkfifo "$TMP_DIR/reuse-test.fifo"
assert_creates_fresh_pre_backup fifo_changed "$last_post_backup" "$CONFIG_DIR" "$TMP_DIR"

# Scenario G: file churn during hashing should degrade to a missing marker instead of failing.
reset_test_env file_churn
mkdir -p "$TMP_DIR/churn"
printf 'volatile\n' >"$TMP_DIR/churn/file.txt"
ORIG_SHA256_DIGEST_FILE_DEF="$(declare -f _sha256_digest_file)"
(
  eval "${ORIG_SHA256_DIGEST_FILE_DEF/_sha256_digest_file/_orig_sha256_digest_file}"
  function _sha256_digest_file() {
    local file="${1:-}"
    rm -f "$file"
    _orig_sha256_digest_file "$file"
  }

  churn_signature="$(_rollback_targets_state_signature "$TMP_DIR")" || exit 1
  [ -n "$churn_signature" ] || exit 1
) || fail_test "Expected state signature calculation to tolerate file churn during hashing"


# Scenario H: traversal churn during directory listing should fall back to a fresh pre backup.
reset_test_env traversal_churn
mkdir -p "$TMP_DIR/walk"
printf 'volatile\n' >"$TMP_DIR/walk/file.txt"
last_post_backup="$(seed_post_backup seed_traversal "$CONFIG_DIR" "$TMP_DIR")"
(
  function _normalize_slashes() {
    local path="${1:-}"
    printf '%s' "$path" | LC_ALL=C sed 's#//*#/#g'
  }

  function find() {
    if [ "$(_normalize_slashes "$PWD")" = "$(_normalize_slashes "$TMP_DIR")" ]; then
      printf './walk/file.txt\n'
      echo "find: './walk/file.txt': No such file or directory" >&2
      return 1
    fi
    command find "$@"
  }

  churn_lines="$(_rollback_target_state_lines "$TMP_DIR")" || exit 1
  printf '%s
' "$churn_lines" | grep -Fq $'C	'"$TMP_DIR"$'	' || exit 1

  begin_transaction "traversal_churn" "$CONFIG_DIR" "$TMP_DIR" || exit 1
  [ "$PRE_CHANGE_BACKUP" != "$last_post_backup" ] || exit 1
  end_transaction_success || exit 1
) || fail_test "Expected traversal churn to fall back to a fresh pre-change backup"

echo "transaction backup reuse correctness checks passed."
