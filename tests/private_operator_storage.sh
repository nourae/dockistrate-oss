#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-private-storage.XXXXXX")"
ORIGINAL_UMASK="$(umask)"
trap 'umask "$ORIGINAL_UMASK"; rm -rf "$TEST_DIR"' EXIT

# Real storage entrypoints with isolated state; no application bootstrap or
# Docker is needed to exercise file creation, replacement, repair, and logging.
for module in utils/common utils/fs utils/csv utils/validators utils/operator_visibility \
  cli/common cli/arg_metadata cli/command_visibility cli/interactive_recents \
  cli/run_command logging/audit_log logging/log_msg permissions/fix_permissions; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done

FAILURES=0
DEFAULT_VISIBILITY_POLICY=full
VISIBILITY_POLICY=full
INTERACTIVE=true
ENABLE_LOGGING=true
VERBOSE=false
INTERACTIVE_RECENTS_NOW=2026-01-01T00:00:00+0000
MARKER=DUMMY_PRIVATE_STORAGE_SECRET
FAIL_CHMOD_TARGET=""
NOOP_CHMOD_TARGET=""
FAIL_MV_TARGET=""

function fail_check() {
  printf '[Error] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

function assert_mode() {
  local file="$1" expected="$2" actual=""
  actual="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || fail_check "$file mode is $actual, expected $expected"
}

function assert_contains() {
  grep -Fq -- "$2" "$1" || fail_check "$1 lost expected fixture value"
}

function assert_absent() {
  if [ -f "$1" ] && grep -Fq -- "$2" "$1"; then
    fail_check "$1 contains rejected fixture value"
  fi
}

function assert_no_temps() {
  local found=""
  found="$(find "$CONFIG_DIR" -name '.*.tmp.*' -type f -print)"
  [ -z "$found" ] || fail_check "history operation left temporary files"
}

function reset_fixture() {
  BASE_DIR="$TEST_DIR/$1"
  STATE_DIR="$BASE_DIR/state"
  CONFIG_DIR="$STATE_DIR/config"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  CERTS_DIR="$STATE_DIR/certs"
  ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
  NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
  NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/http"
  NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream"
  GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
  BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
  CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
  INTERACTIVE_RECENT_FILE="$CONFIG_DIR/interactive_recent.csv"
  INTERACTIVE_FAVORITES_FILE="$CONFIG_DIR/interactive_favorites.csv"
  LOG_FILE="$LOG_DIR/docker_manager.log"
  AUDIT_LOG_FILE="$LOG_DIR/audit.log"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR"
  VISIBILITY_POLICY=full
  INTERACTIVE_RECENTS_LIMIT=10
}

function _nginx_image_runs_as_root() { return 0; }
function docker() { echo '[Error] This fixture must not call Docker.' >&2; return 99; }

# Inject failures without depending on root/non-root access checks. A chmod
# reporting success without changing mode must also be detected by production.
function chmod() {
  local arg=""
  for arg in "$@"; do
    if [ -n "$FAIL_CHMOD_TARGET" ] && [ "$arg" = "$FAIL_CHMOD_TARGET" ]; then
      return 1
    fi
    if [ -n "$NOOP_CHMOD_TARGET" ] && [ "$arg" = "$NOOP_CHMOD_TARGET" ]; then
      return 0
    fi
  done
  command chmod "$@"
}

function mv() {
  local arg="" last=""
  for arg in "$@"; do last="$arg"; done
  if [ -n "$FAIL_MV_TARGET" ] && [ "$last" = "$FAIL_MV_TARGET" ]; then
    return 1
  fi
  command mv "$@"
}

for test_umask in 000 077; do
  reset_fixture "create-$test_umask"
  umask "$test_umask"
  expected_umask="$(umask)"
  saved_args="$(_interactive_command_args_csv response Authorization "Bearer $MARKER, quoted \"value\"")"
  interactive_record_recent_command add-header response Authorization "Bearer $MARKER, quoted \"value\""
  interactive_favorite_command add-header 3 "$saved_args"
  audit_log "full $MARKER"
  log_msg "full $MARKER"
  [ "$(umask)" = "$expected_umask" ] || fail_check 'storage changed caller umask'
  for file in "$INTERACTIVE_RECENT_FILE" "$INTERACTIVE_FAVORITES_FILE" "$AUDIT_LOG_FILE" "$LOG_FILE"; do
    assert_mode "$file" 600
    assert_contains "$file" "$MARKER"
  done
  for loader in interactive_load_recent_commands interactive_load_favorite_commands; do
    "$loader"
    [ "${INTERACTIVE_SAVED_ARGS_CSV[0]:-}" = "$saved_args" ] || fail_check "$loader changed full-policy replay arguments"
  done

  # Reading, duplicate saves, and unfavoriting all repair legacy broad modes.
  command chmod 644 "$INTERACTIVE_RECENT_FILE" "$INTERACTIVE_FAVORITES_FILE"
  interactive_load_recent_commands
  interactive_load_favorite_commands
  assert_mode "$INTERACTIVE_RECENT_FILE" 600
  assert_mode "$INTERACTIVE_FAVORITES_FILE" 600
  command chmod 644 "$INTERACTIVE_FAVORITES_FILE"
  interactive_favorite_command add-header 3 "$saved_args"
  assert_mode "$INTERACTIVE_FAVORITES_FILE" 600
  command chmod 644 "$INTERACTIVE_FAVORITES_FILE"
  interactive_unfavorite_command add-header 3 "$saved_args"
  assert_mode "$INTERACTIVE_FAVORITES_FILE" 600
  assert_absent "$INTERACTIVE_FAVORITES_FILE" "$MARKER"

  VISIBILITY_POLICY=redacted
  interactive_record_recent_command set-nginx-docker-opts "--env TOKEN=NEW_$MARKER"
  interactive_favorite_command set-nginx-docker-opts 1 "$(_interactive_command_args_csv "--env TOKEN=NEW_$MARKER")"
  assert_absent "$INTERACTIVE_RECENT_FILE" "NEW_$MARKER"
  assert_absent "$INTERACTIVE_FAVORITES_FILE" "NEW_$MARKER"
  interactive_load_recent_commands
  [ "${#INTERACTIVE_SAVED_COMMANDS[@]}" -eq 0 ] || fail_check 'redacted history exposed an earlier sensitive command'
  assert_contains "$INTERACTIVE_RECENT_FILE" "$MARKER"
done

reset_fixture failures
interactive_record_recent_command status
interactive_favorite_command status 0 ''
cp "$INTERACTIVE_RECENT_FILE" "$TEST_DIR/before-recent"
cp "$INTERACTIVE_FAVORITES_FILE" "$TEST_DIR/before-favorite"
for file in "$INTERACTIVE_RECENT_FILE" "$INTERACTIVE_FAVORITES_FILE"; do
  command chmod 644 "$file"
  FAIL_CHMOD_TARGET="$file"
  if [ "$file" = "$INTERACTIVE_RECENT_FILE" ]; then
    if interactive_record_recent_command add-header response Authorization "$MARKER" 2>/dev/null; then
      fail_check 'history continued after chmod failure'
    fi
  elif interactive_favorite_command add-header 3 "$(_interactive_command_args_csv response Authorization "$MARKER")" 2>/dev/null; then
    fail_check 'favorite continued after chmod failure'
  fi
  FAIL_CHMOD_TARGET=""
  assert_absent "$file" "$MARKER"
  NOOP_CHMOD_TARGET="$file"
  if _ensure_private_file_permissions "$file" 2>/dev/null; then
    fail_check 'permission verification accepted a no-op chmod'
  fi
  NOOP_CHMOD_TARGET=""
  command chmod 600 "$file"
done

FAIL_MV_TARGET="$INTERACTIVE_RECENT_FILE"
if interactive_record_recent_command add-header response Authorization "$MARKER" 2>/dev/null; then
  fail_check 'history ignored failed atomic replacement'
fi
FAIL_MV_TARGET="$INTERACTIVE_FAVORITES_FILE"
if interactive_favorite_command add-header 3 "$(_interactive_command_args_csv response Authorization "$MARKER")" 2>/dev/null; then
  fail_check 'favorite ignored failed atomic replacement'
fi
FAIL_MV_TARGET=""
cmp -s "$INTERACTIVE_RECENT_FILE" "$TEST_DIR/before-recent" || fail_check 'failed replacement changed recent history'
cmp -s "$INTERACTIVE_FAVORITES_FILE" "$TEST_DIR/before-favorite" || fail_check 'failed replacement changed favorites'
assert_no_temps

# Unsafe paths must not be chmodded, overwritten, appended to, or read into
# saved-command state. Every external target contains only a dummy marker.
for kind in symlink hardlink fifo directory; do
  reset_fixture "unsafe-$kind"
  sentinel="$TEST_DIR/sentinel-$kind"
  printf '%s\n' "$MARKER" >"$sentinel"
  command chmod 644 "$sentinel"
  for file in "$INTERACTIVE_RECENT_FILE" "$INTERACTIVE_FAVORITES_FILE" "$AUDIT_LOG_FILE" "$LOG_FILE"; do
    case "$kind" in
    symlink) ln -s "$sentinel" "$file" ;;
    hardlink) ln "$sentinel" "$file" ;;
    fifo) mkfifo "$file" ;;
    directory) mkdir "$file" ;;
    esac
  done
  if interactive_load_recent_commands >/dev/null 2>&1; then fail_check "$kind history accepted"; fi
  if interactive_load_favorite_commands >/dev/null 2>&1; then fail_check "$kind favorite accepted"; fi
  output="$(audit_log "REJECTED_$MARKER" 2>&1)"
  case "$output" in *"$MARKER"*) fail_check "$kind audit fallback exposed rejected message" ;; esac
  output="$(log_msg "REJECTED_$MARKER" 2>&1)"
  case "$output" in *"$MARKER"*) fail_check "$kind application fallback exposed rejected message" ;; esac
  assert_mode "$sentinel" 644
  [ "$(cat "$sentinel")" = "$MARKER" ] || fail_check "$kind changed external sentinel"
done

reset_fixture parent-link
mkdir "$TEST_DIR/outside"
ln -s "$TEST_DIR/outside" "$CONFIG_DIR/linked"
INTERACTIVE_RECENT_FILE="$CONFIG_DIR/linked/recent.csv"
if interactive_record_recent_command status >/dev/null 2>&1; then fail_check 'symlinked history parent accepted'; fi
[ ! -e "$TEST_DIR/outside/recent.csv" ] || fail_check 'history wrote through parent symlink'

reset_fixture private-log-parent
command chmod 700 "$LOG_DIR"
audit_log "$MARKER"
assert_mode "$LOG_DIR" 700
log_msg "$MARKER"
assert_mode "$LOG_DIR" 700
assert_mode "$AUDIT_LOG_FILE" 600
assert_mode "$LOG_FILE" 600

reset_fixture logging-failures
for logger in audit_log log_msg; do
  case "$logger" in
  audit_log) file="$AUDIT_LOG_FILE" ;;
  log_msg) file="$LOG_FILE" ;;
  esac
  printf '%s\n' 'previous entry' >"$file"
  command chmod 644 "$file"
  FAIL_CHMOD_TARGET="$file"
  output="$("$logger" "REJECTED_$MARKER" 2>&1)"
  FAIL_CHMOD_TARGET=""
  case "$output" in *"$MARKER"*) fail_check 'permission failure printed raw log fallback' ;; esac
  assert_absent "$file" "$MARKER"
done
AUDIT_LOG_FILE=""
output="$(audit_log "REJECTED_$MARKER" 2>&1)"
case "$output" in *"$MARKER"*) fail_check 'missing audit path printed raw fallback' ;; esac
LOG_FILE=""
output="$(log_msg "REJECTED_$MARKER" 2>&1)"
case "$output" in *"$MARKER"*) fail_check 'missing application log path printed raw fallback' ;; esac

reset_fixture logging-write-failures
audit_log 'previous entry'
log_msg 'previous entry'
for logger in audit_log log_msg; do
  output="$(
    function printf() {
      if [ "${1:-}" = '[%s] %s\n' ]; then return 1; fi
      command printf "$@"
    }
    "$logger" "REJECTED_$MARKER" 2>&1
  )"
  case "$output" in *"$MARKER"*) fail_check 'write failure printed raw log fallback' ;; esac
done
assert_absent "$AUDIT_LOG_FILE" "$MARKER"
assert_absent "$LOG_FILE" "$MARKER"
assert_contains "$AUDIT_LOG_FILE" 'previous entry'
assert_contains "$LOG_FILE" 'previous entry'

reset_fixture rotation
dd if=/dev/zero of="$AUDIT_LOG_FILE" bs=1024 count=1025 2>/dev/null
printf '%s\n' "previous $MARKER" >>"$AUDIT_LOG_FILE"
printf '%s\n' 'old rotated entry' >"$AUDIT_LOG_FILE.1"
command chmod 644 "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1"
audit_log 'new audit entry'
assert_mode "$AUDIT_LOG_FILE" 600
assert_mode "$AUDIT_LOG_FILE.1" 600
assert_contains "$AUDIT_LOG_FILE.1" "$MARKER"
assert_contains "$AUDIT_LOG_FILE" 'new audit entry'
assert_absent "$AUDIT_LOG_FILE" "$MARKER"
for kind in symlink hardlink directory; do
  reset_fixture "rotation-$kind"
  dd if=/dev/zero of="$AUDIT_LOG_FILE" bs=1024 count=1025 2>/dev/null
  sentinel="$TEST_DIR/rotation-sentinel-$kind"
  printf '%s\n' 'unchanged' >"$sentinel"
  command chmod 644 "$sentinel"
  case "$kind" in
  symlink) ln -s "$sentinel" "$AUDIT_LOG_FILE.1" ;;
  hardlink) ln "$sentinel" "$AUDIT_LOG_FILE.1" ;;
  directory) mkdir "$AUDIT_LOG_FILE.1" ;;
  esac
  output="$(audit_log "REJECTED_$MARKER" 2>&1)"
  assert_absent "$AUDIT_LOG_FILE" "$MARKER"
  case "$output" in *"$MARKER"*) fail_check "$kind rotation printed raw fallback" ;; esac
  [ "$(cat "$sentinel")" = unchanged ] || fail_check "$kind rotation changed external target"
  assert_mode "$sentinel" 644
done

reset_fixture rotation-failure
dd if=/dev/zero of="$AUDIT_LOG_FILE" bs=1024 count=1025 2>/dev/null
printf '%s\n' 'previous active entry' >>"$AUDIT_LOG_FILE"
printf '%s\n' 'previous rotated entry' >"$AUDIT_LOG_FILE.1"
FAIL_MV_TARGET="$AUDIT_LOG_FILE.1"
output="$(audit_log "REJECTED_$MARKER" 2>&1)"
FAIL_MV_TARGET=""
case "$output" in *"$MARKER"*) fail_check 'rotation failure printed raw log fallback' ;; esac
assert_absent "$AUDIT_LOG_FILE" "$MARKER"
assert_contains "$AUDIT_LOG_FILE" 'previous active entry'
assert_contains "$AUDIT_LOG_FILE.1" 'previous rotated entry'
assert_mode "$AUDIT_LOG_FILE" 600
assert_mode "$AUDIT_LOG_FILE.1" 600

# Failure auditing remains useful and policy-controlled before dispatch.
reset_fixture failed-command
function set_nginx_docker_opts() { return 23; }
for VISIBILITY_POLICY in full redacted; do
  AUDIT_LOG_FILE="$LOG_DIR/$VISIBILITY_POLICY.log"
  rc=0
  run_command set-nginx-docker-opts "--env TOKEN=$MARKER" || rc=$?
  [ "$rc" -eq 23 ] || fail_check 'audit changed command failure status'
  assert_mode "$AUDIT_LOG_FILE" 600
  assert_contains "$AUDIT_LOG_FILE" set-nginx-docker-opts
  if [ "$VISIBILITY_POLICY" = full ]; then
    assert_contains "$AUDIT_LOG_FILE" "$MARKER"
  else
    assert_absent "$AUDIT_LOG_FILE" "$MARKER"
    assert_contains "$AUDIT_LOG_FILE" '[REDACTED]'
  fi
done

# Full mode intentionally retains historical commands; ordinary removal
# command history must not silently erase earlier entries or favorites.
reset_fixture retention
interactive_record_recent_command add-header response Authorization "$MARKER"
interactive_favorite_command add-header 3 "$(_interactive_command_args_csv response Authorization "$MARKER")"
interactive_record_recent_command remove-header response Authorization
interactive_record_recent_command remove-backend example.com
assert_contains "$INTERACTIVE_RECENT_FILE" "$MARKER"
assert_contains "$INTERACTIVE_FAVORITES_FILE" "$MARKER"
INTERACTIVE_RECENTS_LIMIT=2
interactive_record_recent_command status
assert_absent "$INTERACTIVE_RECENT_FILE" "$MARKER"
assert_contains "$INTERACTIVE_FAVORITES_FILE" "$MARKER"
assert_mode "$INTERACTIVE_RECENT_FILE" 600
assert_mode "$INTERACTIVE_FAVORITES_FILE" 600

# Permission repair must never briefly expose previously private artifacts.
# Observe descriptor mutations and retain the PATH shim for unexpected legacy
# utility calls. Both paths must preserve the private ceiling throughout repair.
reset_fixture repair
interactive_record_recent_command status
interactive_favorite_command status 0 ''
audit_log "$MARKER"
log_msg "$MARKER"
printf '%s\n' "$MARKER" >"$AUDIT_LOG_FILE.1"
command chmod 600 "$AUDIT_LOG_FILE.1"
canonical_private_files=("$INTERACTIVE_RECENT_FILE" "$INTERACTIVE_FAVORITES_FILE" "$LOG_FILE" "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1")
INTERACTIVE_RECENT_FILE="$CONFIG_DIR/custom-recent.csv"
INTERACTIVE_FAVORITES_FILE="$CONFIG_DIR/custom-favorites.csv"
LOG_FILE="$LOG_DIR/custom.log"
AUDIT_LOG_FILE="$LOG_DIR/custom-audit.log"
interactive_record_recent_command status
interactive_favorite_command status 0 ''
audit_log "$MARKER"
log_msg "$MARKER"
printf '%s\n' "$MARKER" >"$AUDIT_LOG_FILE.1"
mkdir -p "$TMP_DIR" "$BACKUP_DIR" "$CAPTURE_DIR"
for file in "$BACKEND_DOCKER_OPTS_FILE" "$CAPTURE_TLS_STATE_FILE" "$TMP_DIR/private.tmp" "$BACKUP_DIR/old.tar.gz" "$CAPTURE_DIR/old.pcap"; do
  printf '%s\n' "$MARKER" >"$file"
  command chmod 600 "$file"
done
command chmod 600 "$AUDIT_LOG_FILE.1"
command chmod 700 "$TMP_DIR" "$BACKUP_DIR" "$CAPTURE_DIR"
mkdir "$TEST_DIR/shims"
PRIVATE_CHMOD_REAL="$(type -P chmod)"
PRIVATE_CHMOD_TRACE="$TEST_DIR/chmod.trace"
export PRIVATE_CHMOD_REAL PRIVATE_CHMOD_TRACE
: >"$PRIVATE_CHMOD_TRACE"
eval "$(declare -f _permissions_metadata_mutate_fd | sed '1s/_permissions_metadata_mutate_fd/_test_real_metadata_mutate_fd/')"
function _permissions_metadata_mutate_fd() {
  if [ "$2" = chmod ]; then
    printf '%s|%s\n' "$3" "${PERMISSIONS_TXN_PATHS[$1]}" >>"$PRIVATE_CHMOD_TRACE"
  fi
  _test_real_metadata_mutate_fd "$@"
}
cat >"$TEST_DIR/shims/chmod" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
mode="$1"
shift
for target in "$@"; do
  printf '%s|%s\n' "$mode" "$target" >>"$PRIVATE_CHMOD_TRACE"
done
exec "$PRIVATE_CHMOD_REAL" "$mode" "$@"
SHIM
command chmod 700 "$TEST_DIR/shims/chmod"
PATH="$TEST_DIR/shims:$PATH" fix_permissions "$BASE_DIR" >/dev/null
[ -s "$PRIVATE_CHMOD_TRACE" ] || fail_check 'repair mutation instrumentation was not exercised'
for file in "${canonical_private_files[@]}" "$INTERACTIVE_RECENT_FILE" "$INTERACTIVE_FAVORITES_FILE" "$LOG_FILE" "$AUDIT_LOG_FILE" "$AUDIT_LOG_FILE.1" \
  "$BACKEND_DOCKER_OPTS_FILE" "$CAPTURE_TLS_STATE_FILE" "$TMP_DIR/private.tmp" "$BACKUP_DIR/old.tar.gz" "$CAPTURE_DIR/old.pcap"; do
  assert_mode "$file" 600
  while IFS='|' read -r mode target; do
    if [ "$target" = "$file" ] && [ "$mode" != 600 ]; then
      fail_check "permission repair temporarily widened $file to $mode"
    fi
  done <"$PRIVATE_CHMOD_TRACE"
done
for dir in "$TMP_DIR" "$BACKUP_DIR" "$CAPTURE_DIR"; do
  assert_mode "$dir" 700
  while IFS='|' read -r mode target; do
    if [ "$target" = "$dir" ] && [ "$mode" != 700 ]; then
      fail_check "permission repair temporarily widened $dir to $mode"
    fi
  done <"$PRIVATE_CHMOD_TRACE"
done

# Custom paths may name the same physical storage through an external alias.
# The state guard permits these aliases when they resolve inside STATE_DIR.
# Repair must identify the physical private file/subtree before normalizing it.
physical_config="$CONFIG_DIR"
physical_backup="$BACKUP_DIR"
physical_audit="$AUDIT_LOG_FILE"
physical_log="$LOG_FILE"
ln -s "$CONFIG_DIR" "$TEST_DIR/config-alias"
ln -s "$STATE_DIR" "$TEST_DIR/state-alias"
CONFIG_DIR="$TEST_DIR/config-alias"
INTERACTIVE_RECENT_FILE="$CONFIG_DIR/custom-recent.csv"
INTERACTIVE_FAVORITES_FILE="$CONFIG_DIR/custom-favorites.csv"
BACKUP_DIR="$TEST_DIR/state-alias/backups"
AUDIT_LOG_FILE="$TEST_DIR/state-alias/logs/custom-audit.log"
LOG_FILE="$TEST_DIR/state-alias/logs/custom.log"
: >"$PRIVATE_CHMOD_TRACE"
PATH="$TEST_DIR/shims:$PATH" fix_permissions "$BASE_DIR" >/dev/null
for file in "${canonical_private_files[@]}" "$physical_config/custom-recent.csv" "$physical_config/custom-favorites.csv" \
  "$physical_audit" "$physical_audit.1" "$physical_log" "$physical_backup/old.tar.gz"; do
  assert_mode "$file" 600
  while IFS='|' read -r mode target; do
    if [ "$target" -ef "$file" ] && [ "$mode" != 600 ]; then
      fail_check "repair widened aliased private file to $mode"
    fi
  done <"$PRIVATE_CHMOD_TRACE"
done
assert_mode "$physical_backup" 700
while IFS='|' read -r mode target; do
  if [ "$target" -ef "$physical_backup" ] && [ "$mode" != 700 ]; then
    fail_check "repair widened aliased private directory to $mode"
  fi
done <"$PRIVATE_CHMOD_TRACE"

# Invalid declared paths must fail before the normalization walk writes modes.
CONFIG_DIR="$STATE_DIR/../state/config"
: >"$PRIVATE_CHMOD_TRACE"
if PATH="$TEST_DIR/shims:$PATH" fix_permissions "$BASE_DIR" >/dev/null 2>&1; then
  fail_check 'repair accepted a declared dot-dot configuration path'
fi
[ ! -s "$PRIVATE_CHMOD_TRACE" ] || fail_check 'repair changed modes before rejecting invalid runtime paths'

if [ "$FAILURES" -ne 0 ]; then
  printf '[Error] Private storage checks failed: %s\n' "$FAILURES" >&2
  exit 1
fi
echo '[tests] private_operator_storage.sh: PASS'
