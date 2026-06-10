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
source "$ROOT_DIR/lib/nginx.sh"

RESTORE_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore_backup_runtime_recovery.d"
if [ -d "$RESTORE_TEST_DIR" ]; then
  for stub_file in "$RESTORE_TEST_DIR"/*.sh; do
    # shellcheck disable=SC1090
    . "$stub_file"
  done
fi

TMP_ROOT="$(_realpath_portable "$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_restore_runtime.XXXXXX")")"
trap 'rm -rf "$TMP_ROOT"' EXIT

BASE_DIR="$TMP_ROOT"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha1"
NGINX_CONTAINER_NAME="nginx-proxy"
NGINX_IMAGE="nginx:1.28.1"
TRACE_FILE="$TMP_ROOT/trace.log"
ORIG_RUNTIME_STATE_PATH_GUARD_IF_DECLARED_DEF="$(declare -f runtime_state_path_guard_if_declared)"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$expected" != "$actual" ]; then
    fail_test "$message (expected '$expected', got '$actual')"
  fi
}

function assert_file_exists() {
  local path="$1"
  [ -f "$path" ] || fail_test "Expected file to exist: $path"
}

function assert_file_missing() {
  local path="$1"
  [ ! -e "$path" ] || fail_test "Expected path to be missing: $path"
}

function assert_file_contains_line() {
  local path="$1"
  local needle="$2"
  grep -qx "$needle" "$path" || fail_test "Expected '$needle' in $path"
}

function assert_trace_contains_line() {
  local needle="$1"
  grep -qx "$needle" "$TRACE_FILE" || fail_test "Expected trace line '$needle'"
}

function count_trace() {
  local key="$1"
  awk -v needle="$key" '$0 == needle { c++ } END { print c + 0 }' "$TRACE_FILE"
}

function count_trace_before() {
  local key="$1"
  local stop_key="$2"
  awk -v needle="$key" -v stop="$stop_key" '
    $0 == stop { exit }
    $0 == needle { c++ }
    END { print c + 0 }
  ' "$TRACE_FILE"
}

function get_inode_value() {
  local path="$1"
  if stat -c '%i' "$path" >/dev/null 2>&1; then
    stat -c '%i' "$path"
  else
    stat -f '%i' "$path"
  fi
}

function reset_runtime_state() {
  local marker="$1"
  rm -rf "$STATE_DIR"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$ERROR_LOG_DIR" "$TMP_DIR" "$BACKUP_DIR" \
    "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR"
  : >"$TRACE_FILE"

  cat >"$CONFIG_DIR/marker.txt" <<EOF_MARKER
$marker
EOF_MARKER
  cat >"$CONFIG_DIR/legacy.txt" <<'EOF_LEGACY'
legacy
EOF_LEGACY
  cat >"$NGINX_CONFIG_DIR/nginx.conf" <<'EOF_NGINX'
worker_processes  1;
events {}
http {}
EOF_NGINX

  ENABLE_AUTO_BACKUPS="true"
  BACKUP_RETENTION="0"
  ENABLE_BACKUP_COMPRESSION="true"
  STUB_FIND_FAIL_MATCH=""
  STUB_CONTAINER_RUNNING="false"
  STUB_CONTAINER_EXISTS="false"
  STUB_CHECK_CONFIG_FAIL="false"
  STUB_SAFE_RM_RF_FAIL_MATCH=""
  STUB_PUBLISHED_BINDINGS="80/tcp"
  STUB_NEW_BINDINGS="81/tcp"
  STUB_RECREATE_FAIL_ON_CALL="0"
  STUB_CAPTURE_DOCKER_LOGS_FAIL="false"
  STUB_RUNNING_IMAGE="$NGINX_IMAGE"
  SKIP_DOCKER_CHECKS="false"
  LAST_FIX_TARGET=""
  LAST_RECREATE_IMAGE=""
  LAST_RECREATE_BINDINGS=""
  RECREATE_CALL_COUNT=0
}

function create_restore_archive() {
  local name="$1"
  local marker="$2"
  local payload_root="$TMP_ROOT/payload_${name}"
  local payload_dir="$payload_root/${name}"
  # Test-only cleanup of deterministic temp fixture directory under TMP_ROOT.
  rm -rf "$payload_root" # input-validation-audit: ignore
  mkdir -p "$payload_dir/config/nginx_conf/conf.d"
  cat >"$payload_dir/config/marker.txt" <<EOF_MARKER
$marker
EOF_MARKER
  cat >"$payload_dir/config/new_only.txt" <<'EOF_NEW'
new
EOF_NEW
  cat >"$payload_dir/config/nginx_conf/nginx.conf" <<'EOF_NGINX'
worker_processes  auto;
events {}
http {}
EOF_NGINX
  (cd "$payload_root" && tar -czf "$BACKUP_DIR/${name}.tar.gz" "$name")
  printf '%s.tar.gz\n' "$name"
}

# Scenario A: in-place restore preserves CONFIG_DIR inode and replaces contents.
reset_runtime_state "old-a"
SKIP_DOCKER_CHECKS="true"
archive_name="$(create_restore_archive "restore_a" "new-a")"
inode_before="$(get_inode_value "$CONFIG_DIR")"
restore_backup "$archive_name"
inode_after="$(get_inode_value "$CONFIG_DIR")"
assert_equals "$inode_before" "$inode_after" "CONFIG_DIR inode should remain unchanged"
assert_file_contains_line "$CONFIG_DIR/marker.txt" "new-a"
assert_file_exists "$CONFIG_DIR/new_only.txt"
assert_file_missing "$CONFIG_DIR/legacy.txt"
if [ "$(count_trace "safe_rm_rf")" -lt 1 ]; then
  fail_test "safe_rm_rf should run during restore config cleanup"
fi
assert_equals "1" "$(count_trace "fix_permissions")" "fix_permissions should run once"
assert_equals "1" "$(count_trace "update_nginx_config")" "update_nginx_config should run once"
assert_equals "0" "$(count_trace "recreate_nginx_container")" "recreate should not run with SKIP_DOCKER_CHECKS=true"
assert_equals "0" "$(count_trace "check_config")" "check_config should not run with SKIP_DOCKER_CHECKS=true"
assert_equals "$CONFIG_DIR" "$LAST_FIX_TARGET" "fix_permissions should target CONFIG_DIR"

# Scenario B: running Nginx triggers recreate + check_config.
reset_runtime_state "old-b"
SKIP_DOCKER_CHECKS="false"
STUB_CONTAINER_RUNNING="true"
STUB_CONTAINER_EXISTS="true"
archive_name="$(create_restore_archive "restore_b" "new-b")"
restore_backup "$archive_name"
assert_equals "1" "$(count_trace "fix_permissions")" "fix_permissions should run once"
assert_equals "1" "$(count_trace "update_nginx_config")" "update_nginx_config should run once"
assert_equals "1" "$(count_trace "recreate_nginx_container")" "recreate should run when Nginx was running"
assert_equals "1" "$(count_trace "check_config")" "check_config should run when container exists"
assert_equals "$NGINX_IMAGE" "$LAST_RECREATE_IMAGE" "recreate should use configured NGINX_IMAGE"

# Scenario C: SKIP_DOCKER_CHECKS=true suppresses recreate/check even if Nginx is running.
reset_runtime_state "old-c"
SKIP_DOCKER_CHECKS="true"
STUB_CONTAINER_RUNNING="true"
STUB_CONTAINER_EXISTS="true"
archive_name="$(create_restore_archive "restore_c" "new-c")"
restore_backup "$archive_name"
assert_equals "1" "$(count_trace "fix_permissions")" "fix_permissions should run once"
assert_equals "1" "$(count_trace "update_nginx_config")" "update_nginx_config should run once"
assert_equals "0" "$(count_trace "recreate_nginx_container")" "recreate should be skipped when SKIP_DOCKER_CHECKS=true"
assert_equals "0" "$(count_trace "check_config")" "check_config should be skipped when SKIP_DOCKER_CHECKS=true"

# Scenario D: failing check_config rolls back restored files.
reset_runtime_state "old-d"
SKIP_DOCKER_CHECKS="false"
STUB_CONTAINER_RUNNING="true"
STUB_CONTAINER_EXISTS="true"
STUB_CHECK_CONFIG_FAIL="true"
archive_name="$(create_restore_archive "restore_d" "new-d")"
set +e
(restore_backup "$archive_name")
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "restore_backup should fail when check_config fails"
fi
assert_file_contains_line "$CONFIG_DIR/marker.txt" "old-d"
assert_file_exists "$CONFIG_DIR/legacy.txt"
assert_file_missing "$CONFIG_DIR/new_only.txt"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "recreate should run for restore and rollback recovery"
if [ "$(count_trace "check_config")" -lt 1 ]; then
  fail_test "check_config should run before rollback"
fi
assert_equals "1" "$(count_trace "remove_container_and_anonymous_volumes")" "rollback should remove the failed recreated container"
assert_trace_contains_line "recreate_nginx_container:2:${NGINX_IMAGE}:80/tcp"

# Scenario E: failing safe_rm_rf rolls back restored files.
reset_runtime_state "old-e"
SKIP_DOCKER_CHECKS="true"
STUB_SAFE_RM_RF_FAIL_MATCH="*"
archive_name="$(create_restore_archive "restore_e" "new-e")"
set +e
(restore_backup "$archive_name")
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "restore_backup should fail when safe_rm_rf rejects a target"
fi
assert_file_contains_line "$CONFIG_DIR/marker.txt" "old-e"
assert_file_exists "$CONFIG_DIR/legacy.txt"
assert_file_missing "$CONFIG_DIR/new_only.txt"
assert_equals "1" "$(count_trace_before "safe_rm_rf" "capture_docker_logs")" "restore cleanup should stop after the first safe_rm_rf rejection"

# Scenario F: absolute archive path is accepted.
reset_runtime_state "old-f"
SKIP_DOCKER_CHECKS="true"
archive_name="$(create_restore_archive "restore_f" "new-f")"
external_archive="$TMP_ROOT/absolute_restore/restore_f_absolute.tar.gz"
mkdir -p "$(dirname "$external_archive")"
cp "$BACKUP_DIR/$archive_name" "$external_archive"
restore_backup "$external_archive"
assert_file_contains_line "$CONFIG_DIR/marker.txt" "new-f"
assert_file_exists "$CONFIG_DIR/new_only.txt"
assert_file_missing "$CONFIG_DIR/legacy.txt"

# Scenario G: existing relative path (no slash in argument) is treated as a path.
reset_runtime_state "old-g"
SKIP_DOCKER_CHECKS="true"
archive_name="$(create_restore_archive "restore_g" "new-g")"
relative_dir="$TMP_ROOT/relative_restore"
mkdir -p "$relative_dir"
cp "$BACKUP_DIR/$archive_name" "$relative_dir/restore_g.tar.gz"
(
  cd "$relative_dir"
  restore_backup "restore_g.tar.gz"
)
assert_file_contains_line "$CONFIG_DIR/marker.txt" "new-g"
assert_file_exists "$CONFIG_DIR/new_only.txt"
assert_file_missing "$CONFIG_DIR/legacy.txt"

# Scenario H: failing recreate rolls back restored files and restores runtime.
reset_runtime_state "old-h"
SKIP_DOCKER_CHECKS="false"
STUB_CONTAINER_RUNNING="true"
STUB_CONTAINER_EXISTS="true"
STUB_RECREATE_FAIL_ON_CALL="1"
archive_name="$(create_restore_archive "restore_h" "new-h")"
set +e
(restore_backup "$archive_name")
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "restore_backup should fail when recreate_nginx_container fails"
fi
assert_file_contains_line "$CONFIG_DIR/marker.txt" "old-h"
assert_file_exists "$CONFIG_DIR/legacy.txt"
assert_file_missing "$CONFIG_DIR/new_only.txt"
assert_equals "2" "$(count_trace "recreate_nginx_container")" "rollback should attempt a second recreate after recreate failure"
assert_trace_contains_line "recreate_nginx_container:2:${NGINX_IMAGE}:80/tcp"

# Scenario I: failing find enumeration rolls back restored files.
reset_runtime_state "old-i"
SKIP_DOCKER_CHECKS="true"
STUB_FIND_FAIL_MATCH="$CONFIG_DIR"
archive_name="$(create_restore_archive "restore_i" "new-i")"
set +e
(restore_backup "$archive_name")
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "restore_backup should fail when find cannot enumerate CONFIG_DIR"
fi
assert_file_contains_line "$CONFIG_DIR/marker.txt" "old-i"
assert_file_exists "$CONFIG_DIR/legacy.txt"
assert_file_missing "$CONFIG_DIR/new_only.txt"
assert_equals "0" "$(count_trace "safe_rm_rf")" "safe_rm_rf should not run when find enumeration fails"

# Scenario J: rollback continues even if Docker log capture cannot write logs.
reset_runtime_state "old-j"
SKIP_DOCKER_CHECKS="false"
STUB_CONTAINER_RUNNING="true"
STUB_CONTAINER_EXISTS="true"
STUB_CHECK_CONFIG_FAIL="true"
STUB_CAPTURE_DOCKER_LOGS_FAIL="true"
archive_name="$(create_restore_archive "restore_j" "new-j")"
set +e
(restore_backup "$archive_name") >/dev/null 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
  fail_test "restore_backup should fail when check_config fails even if rollback log capture fails"
fi
assert_file_contains_line "$CONFIG_DIR/marker.txt" "old-j"
assert_file_exists "$CONFIG_DIR/legacy.txt"
assert_file_missing "$CONFIG_DIR/new_only.txt"
assert_equals "1" "$(count_trace "capture_docker_logs")" "rollback should attempt docker log capture"

# Scenario K: a runtime path guard failure after transaction start must not continue restore work.
reset_runtime_state "old-k"
SKIP_DOCKER_CHECKS="true"
archive_name="$(create_restore_archive "restore_k" "new-k")"
set +e
(
  eval "$(printf '%s\n' "$ORIG_RUNTIME_STATE_PATH_GUARD_IF_DECLARED_DEF" | sed '1s/runtime_state_path_guard_if_declared/original_runtime_state_path_guard_if_declared/')"
  function runtime_state_path_guard_if_declared() {
    if transaction_is_active && [ "${1:-}" = "$CONFIG_DIR" ]; then
      _restore_trace_append "runtime_state_path_guard_if_declared"
      echo "[Error] Refusing to use restore config directory for runtime guard test." >&2
      return 1
    fi
    original_runtime_state_path_guard_if_declared "$@"
  }
  function _rollback_handler() {
    _restore_trace_append "_rollback_handler"
    return 1
  }

  set +e
  restore_backup "$archive_name" >/dev/null 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    fail_test "restore_backup should fail when runtime path guard rejects CONFIG_DIR after begin_transaction"
  fi
)
guard_subshell_status=$?
set -e
if [ "$guard_subshell_status" -eq 0 ]; then
  fail_test "runtime path guard failure scenario should exit non-zero"
fi
assert_file_contains_line "$CONFIG_DIR/marker.txt" "old-k"
assert_file_exists "$CONFIG_DIR/legacy.txt"
assert_file_missing "$CONFIG_DIR/new_only.txt"
assert_equals "1" "$(count_trace "runtime_state_path_guard_if_declared")" "restore should hit the injected runtime path guard failure"
assert_equals "0" "$(count_trace "update_nginx_config")" "restore should not continue after runtime path guard failure"

echo "restore_backup runtime recovery tests passed."
