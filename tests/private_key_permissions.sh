#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-private-keys.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
ORIGINAL_PATH="$PATH"
REAL_CHMOD="$(type -P chmod)"
REAL_CHOWN="$(type -P chown)"
REAL_CHGRP="$(type -P chgrp)"
REAL_GREP="$(type -P grep)"
TEST_PRIMARY_GID="$(id -g)"
trap 'PATH="$ORIGINAL_PATH"; "$REAL_CHMOD" -R u+rwX "$TEST_DIR"; rm -rf "$TEST_DIR"' EXIT

# Exercise production permission entrypoints without application bootstrap or
# Docker. Every configured path, including active state, is inside this fixture.
# shellcheck source=../lib/permissions/fix_permissions.sh
source "$ROOT_DIR/lib/permissions/fix_permissions.sh"
function _nginx_image_runs_as_root() { return 0; }

FAILURES=0
CHMOD_TRACE="$TEST_DIR/chmod.trace"
CHOWN_TRACE="$TEST_DIR/chown.trace"
FAIL_CHMOD_TARGET=""
NOOP_CHMOD_TARGET=""
FAIL_CHOWN_TARGET=""
NOOP_CHOWN_TARGET=""
PARTIAL_CHOWN_TARGET=""
PARTIAL_CHOWN_MODE=""
PARTIAL_CHOWN_APPLY=false
PARTIAL_CHOWN_ONCE="$TEST_DIR/partial-chown-once"
FAIL_GREP_TARGET=""
PARTIAL_CHMOD_TARGET=""
PARTIAL_CHMOD_MODE=""
SIGNAL_CHMOD_TARGET=""
SIGNAL_CHMOD_ONCE="$TEST_DIR/signal-chmod-once"
export SIGNAL_CHMOD_TARGET SIGNAL_CHMOD_ONCE
CONCURRENT_TRIGGER_TARGET=""
CONCURRENT_CHANGED_TARGET=""
CONCURRENT_CHANGE_ONCE="$TEST_DIR/concurrent-change-once"
export CONCURRENT_TRIGGER_TARGET CONCURRENT_CHANGED_TARGET CONCURRENT_CHANGE_ONCE
PARTIAL_CHMOD_ONCE="$TEST_DIR/partial-chmod-once"
ROLLBACK_FAIL_TARGET=""
export PARTIAL_CHMOD_TARGET PARTIAL_CHMOD_MODE PARTIAL_CHMOD_ONCE ROLLBACK_FAIL_TARGET
export REAL_CHMOD REAL_CHOWN REAL_GREP CHMOD_TRACE CHOWN_TRACE
export FAIL_GREP_TARGET NOOP_CHOWN_TARGET PARTIAL_CHOWN_TARGET PARTIAL_CHOWN_MODE
export PARTIAL_CHOWN_APPLY PARTIAL_CHOWN_ONCE
export FAIL_CHMOD_TARGET NOOP_CHMOD_TARGET FAIL_CHOWN_TARGET
mkdir "$TEST_DIR/shims"
cat >"$TEST_DIR/shims/chmod" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
for arg in "$@"; do
  printf '%s\n' "$arg" >>"$CHMOD_TRACE"
  if [ -n "${CONCURRENT_TRIGGER_TARGET:-}" ] && [ "$arg" = "$CONCURRENT_TRIGGER_TARGET" ] && [ ! -e "$CONCURRENT_CHANGE_ONCE" ]; then
    before_mode="$(stat -c '%a' "$CONCURRENT_CHANGED_TARGET" 2>/dev/null || stat -f '%Lp' "$CONCURRENT_CHANGED_TARGET")"
    "$REAL_CHMOD" 400 "$CONCURRENT_CHANGED_TARGET"
    printf '%s\n' "$before_mode" >"$CONCURRENT_CHANGE_ONCE"
  fi
  if [ -n "${SIGNAL_CHMOD_TARGET:-}" ] && [ "$arg" = "$SIGNAL_CHMOD_TARGET" ] && [ ! -e "$SIGNAL_CHMOD_ONCE" ]; then
    "$REAL_CHMOD" "$@"
    : >"$SIGNAL_CHMOD_ONCE"
    kill -TERM "$PPID"
    exit 0
  fi
  if [ -n "${PARTIAL_CHMOD_TARGET:-}" ] && [ "$arg" = "$PARTIAL_CHMOD_TARGET" ] && [ ! -e "$PARTIAL_CHMOD_ONCE" ]; then
    if [ -n "${PARTIAL_CHMOD_MODE:-}" ]; then
      "$REAL_CHMOD" "$PARTIAL_CHMOD_MODE" "$arg"
    else
      "$REAL_CHMOD" "$@"
    fi
    : >"$PARTIAL_CHMOD_ONCE"
    exit 1
  fi
  if [ -n "${ROLLBACK_FAIL_TARGET:-}" ] && [ "$arg" = "$ROLLBACK_FAIL_TARGET" ] && [ -e "$PARTIAL_CHMOD_ONCE" ]; then
    exit 1
  fi
  if [ -n "${FAIL_CHMOD_TARGET:-}" ] && [ "$arg" = "$FAIL_CHMOD_TARGET" ]; then
    exit 1
  fi
  if [ -n "${NOOP_CHMOD_TARGET:-}" ] && [ "$arg" = "$NOOP_CHMOD_TARGET" ]; then
    exit 0
  fi
done
exec "$REAL_CHMOD" "$@"
SHIM
cat >"$TEST_DIR/shims/chown" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
for arg in "$@"; do
  printf '%s\n' "$arg" >>"$CHOWN_TRACE"
  if [ -n "${CONCURRENT_TRIGGER_TARGET:-}" ] && [ "$arg" = "$CONCURRENT_TRIGGER_TARGET" ] && [ ! -e "$CONCURRENT_CHANGE_ONCE" ]; then
    before_mode="$(stat -c '%a' "$CONCURRENT_CHANGED_TARGET" 2>/dev/null || stat -f '%Lp' "$CONCURRENT_CHANGED_TARGET")"
    "$REAL_CHMOD" 400 "$CONCURRENT_CHANGED_TARGET"
    printf '%s\n' "$before_mode" >"$CONCURRENT_CHANGE_ONCE"
  fi
  if [ -n "${NOOP_CHOWN_TARGET:-}" ] && [ "$arg" = "$NOOP_CHOWN_TARGET" ]; then
    exit 0
  fi
  if [ -n "${PARTIAL_CHOWN_TARGET:-}" ] && [ "$arg" = "$PARTIAL_CHOWN_TARGET" ] && [ ! -e "$PARTIAL_CHOWN_ONCE" ]; then
    if [ "${PARTIAL_CHOWN_APPLY:-false}" = true ]; then
      "$REAL_CHOWN" "$@"
    elif [ -n "${PARTIAL_CHOWN_MODE:-}" ]; then
      "$REAL_CHMOD" "$PARTIAL_CHOWN_MODE" "$arg"
    else
      "$REAL_CHMOD" u-s,g-s "$arg"
    fi
    : >"$PARTIAL_CHOWN_ONCE"
    exit 1
  fi
  if [ -n "${FAIL_CHOWN_TARGET:-}" ] && [ "$arg" = "$FAIL_CHOWN_TARGET" ]; then
    exit 1
  fi
done
exec "$REAL_CHOWN" "$@"
SHIM
cat >"$TEST_DIR/shims/grep" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
for arg in "$@"; do
  if [ -n "${FAIL_GREP_TARGET:-}" ] && [ "$arg" = "$FAIL_GREP_TARGET" ]; then
    exit 2
  fi
done
exec "$REAL_GREP" "$@"
SHIM
"$REAL_CHMOD" 700 "$TEST_DIR/shims/chmod" "$TEST_DIR/shims/chown" "$TEST_DIR/shims/grep"
PATH="$TEST_DIR/shims:$PATH"


# Fault injection follows the same transaction boundary after its pathname
# guards, while ordinary mutations execute the real descriptor-bound helper.
# TLS helpers above still use utility shims; repair no longer invokes utilities.
eval "$(declare -f _permissions_metadata_mutate_fd | sed '1s/_permissions_metadata_mutate_fd/_test_real_metadata_mutate_fd/')"
function _permissions_metadata_mutate_fd() {
  local operation="$2" path="${PERMISSIONS_TXN_PATHS[$1]}" before_mode=""
  if [ "$operation" = chmod ]; then
    printf '%s\n' "$3" "$path" >>"$CHMOD_TRACE"
  else
    printf '%s\n' "$3:${4:-}" "$path" >>"$CHOWN_TRACE"
  fi
  if [ -n "$CONCURRENT_TRIGGER_TARGET" ] && [ "$path" = "$CONCURRENT_TRIGGER_TARGET" ] && [ ! -e "$CONCURRENT_CHANGE_ONCE" ]; then
    before_mode="$(mode_of "$CONCURRENT_CHANGED_TARGET")"
    "$REAL_CHMOD" 400 "$CONCURRENT_CHANGED_TARGET"
    printf '%s\n' "$before_mode" >"$CONCURRENT_CHANGE_ONCE"
  fi
  if [ "$operation" = chmod ]; then
    if [ -n "$SIGNAL_CHMOD_TARGET" ] && [ "$path" = "$SIGNAL_CHMOD_TARGET" ] && [ ! -e "$SIGNAL_CHMOD_ONCE" ]; then
      _test_real_metadata_mutate_fd "$@" || return 1
      : >"$SIGNAL_CHMOD_ONCE"
      "$BASH" -c 'kill -TERM "$PPID"'
      return 0
    fi
    if [ -n "$PARTIAL_CHMOD_TARGET" ] && [ "$path" = "$PARTIAL_CHMOD_TARGET" ] && [ ! -e "$PARTIAL_CHMOD_ONCE" ]; then
      if [ -n "$PARTIAL_CHMOD_MODE" ]; then
        "$REAL_CHMOD" "$PARTIAL_CHMOD_MODE" "$path"
      else
        _test_real_metadata_mutate_fd "$@" || return 1
      fi
      : >"$PARTIAL_CHMOD_ONCE"
      return 1
    fi
    if [ -n "$ROLLBACK_FAIL_TARGET" ] && [ "$path" = "$ROLLBACK_FAIL_TARGET" ] && [ -e "$PARTIAL_CHMOD_ONCE" ]; then return 1; fi
    if [ -n "$FAIL_CHMOD_TARGET" ] && [ "$path" = "$FAIL_CHMOD_TARGET" ]; then return 1; fi
    if [ -n "$NOOP_CHMOD_TARGET" ] && [ "$path" = "$NOOP_CHMOD_TARGET" ]; then return 0; fi
  else
    if [ -n "$NOOP_CHOWN_TARGET" ] && [ "$path" = "$NOOP_CHOWN_TARGET" ]; then return 0; fi
    if [ -n "$PARTIAL_CHOWN_TARGET" ] && [ "$path" = "$PARTIAL_CHOWN_TARGET" ] && [ ! -e "$PARTIAL_CHOWN_ONCE" ]; then
      if [ "$PARTIAL_CHOWN_APPLY" = true ]; then
        _test_real_metadata_mutate_fd "$@" || return 1
      elif [ -n "$PARTIAL_CHOWN_MODE" ]; then
        "$REAL_CHMOD" "$PARTIAL_CHOWN_MODE" "$path"
      else
        "$REAL_CHMOD" u-s,g-s "$path"
      fi
      : >"$PARTIAL_CHOWN_ONCE"
      return 1
    fi
    if [ -n "$FAIL_CHOWN_TARGET" ] && [ "$path" = "$FAIL_CHOWN_TARGET" ]; then return 1; fi
  fi
  _test_real_metadata_mutate_fd "$@"
}

function fail_check() {
  printf '[Error] %s\n' "$*" >&2
  if [ -n "${LAST_REPAIR_OUTPUT:-}" ]; then printf '%s\n' "$LAST_REPAIR_OUTPUT" >&2; fi
  FAILURES=$((FAILURES + 1))
}

function mode_of() {
  local raw_mode=""
  if ! raw_mode="$(stat -c '%a' "$1" 2>/dev/null || exit 1)"; then
    raw_mode="$(stat -f '%p' "$1" || exit 1)" || return 1
  fi
  case "$raw_mode" in '' | *[!0-7]*) return 1 ;; esac
  # BSD %Lp omits set-ID and sticky bits. Observe full permissions independently
  # of the production helpers, removing only the file type returned by %p.
  printf '%o\n' "$((8#$raw_mode & 07777))"
}

function assert_mode() {
  local actual=""
  actual="$(mode_of "$1")"
  [ "$actual" = "$2" ] || fail_check "$3: mode $actual, expected $2"
}

function reset_fixture() {
  LAST_REPAIR_OUTPUT=""
  BASE_DIR="$TEST_DIR/$1/active"
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
  TARGET_DIR="$TEST_DIR/$1/repair"
  mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$CERTS_DIR" "$TARGET_DIR"
  FAIL_CHMOD_TARGET=""
  NOOP_CHMOD_TARGET=""
  FAIL_CHOWN_TARGET=""
  NOOP_CHOWN_TARGET=""
  PARTIAL_CHOWN_TARGET=""
  PARTIAL_CHOWN_MODE=""
  PARTIAL_CHOWN_APPLY=false
  FAIL_GREP_TARGET=""
  PARTIAL_CHMOD_TARGET=""
  PARTIAL_CHMOD_MODE=""
  SIGNAL_CHMOD_TARGET=""
  CONCURRENT_TRIGGER_TARGET=""
  CONCURRENT_CHANGED_TARGET=""
  ROLLBACK_FAIL_TARGET=""
  rm -f "$PARTIAL_CHMOD_ONCE" "$PARTIAL_CHOWN_ONCE" "$SIGNAL_CHMOD_ONCE" "$CONCURRENT_CHANGE_ONCE"
  : >"$CHMOD_TRACE"
  : >"$CHOWN_TRACE"
}

function make_file() {
  printf '%s\n' 'DUMMY_PRIVATE_KEY_FIXTURE' >"$1"
  "$REAL_CHGRP" "$TEST_PRIMARY_GID" "$1"
  "$REAL_CHMOD" "$2" "$1"
}

function expect_repair_failure() {
  local output=""
  if output="$(fix_permissions "$TARGET_DIR" 2>&1)"; then
    fail_check "$1: repair reported success"
  fi
  LAST_REPAIR_OUTPUT="$output"
  case "$output" in
  *'Permissions normalization complete'*) fail_check "$1: misleading completion message" ;;
  esac
}

# The target can be an extracted backup or an arbitrary operator directory; it
# does not have to be the configured live certificate tree.
reset_fixture custom
for name in privkey.pem privkey7.pem server.key client.p12 CLIENT.PFX SERVER.KEY Key.PEM PrivKey9.PEM; do
  make_file "$TARGET_DIR/$name" 666
done
make_file "$TARGET_DIR/public.crt" 600
make_file "$TARGET_DIR/run-helper" 700
fix_permissions "$TARGET_DIR" >/dev/null
for name in privkey.pem privkey7.pem server.key client.p12 CLIENT.PFX SERVER.KEY Key.PEM PrivKey9.PEM; do
  assert_mode "$TARGET_DIR/$name" 600 "custom target $name"
done
assert_mode "$TARGET_DIR/public.crt" 600 'ordinary certificate restrictive mode preservation'
[ -x "$TARGET_DIR/run-helper" ] || fail_check 'ordinary executable became non-executable'

# Filesystem iteration and mode planning must preserve unusual but valid path
# names; line-delimited traversal can silently split a private key pathname.
reset_fixture unusual-paths
mkdir "$TARGET_DIR/directory with spaces"
file="$TARGET_DIR/directory with spaces/"$'line\nbreak.KEY'
make_file "$file" 644
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$file" 600 'newline-containing key pathname'

# Option-like and trailing-newline targets are literal directory operands.
# The shim and fixture OLDPWD make old cd forms fail without leaving the test.
reset_fixture option-target
mkdir "$TARGET_DIR/selected" "$TARGET_DIR/old-directory"
make_file "$TARGET_DIR/selected/prefix.key" 644
make_file "$TARGET_DIR/old-directory/old.key" 644
make_file "$TARGET_DIR/outside.key" 644
for target_name in -P - $'selected\n'; do
  mkdir "$TARGET_DIR/$target_name"
  make_file "$TARGET_DIR/$target_name/selected.key" 644
  if ! (
    function cd() {
      local last=""
      for last in "$@"; do :; done
      if { [ "$#" -eq 1 ] && [ "$1" = -P ]; } || [ "$last" = - ]; then
        return 99
      fi
      builtin cd "$@"
    }
    builtin cd "$TARGET_DIR"
    OLDPWD="$TARGET_DIR/old-directory"
    fix_permissions "$target_name"
  ) >/dev/null; then
    fail_check 'literal directory target was not repaired'
  fi
  assert_mode "$TARGET_DIR/$target_name/selected.key" 600 'literal directory target key'
  assert_mode "$TARGET_DIR/outside.key" 644 'literal directory target sibling'
  assert_mode "$TARGET_DIR/old-directory/old.key" 644 'literal target leaves OLDPWD untouched'
  assert_mode "$TARGET_DIR/selected/prefix.key" 644 'newline target leaves prefix sibling untouched'
done

# A custom TMPDIR alias can point into the repair tree. Its own temporary
# inventory must not become a repair entry after the inventory is removed.
reset_fixture 'inventory-[alias]'
ln -s "$TARGET_DIR" "$TEST_DIR/inventory-path-alias"
make_file "$TARGET_DIR/server.key" 644
TMPDIR="$TEST_DIR/inventory-path-alias" fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$TARGET_DIR/server.key" 600 'temporary inventory alias repair'

# Sensitive filename patterns apply to the basename, not a parent's name.
# Public certificates under an operator directory named privkeys stay public.
reset_fixture filename-only
mkdir "$TARGET_DIR/privkeys"
for name in certificate.pem helper-public.pem; do
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'DUMMY_PUBLIC_CERTIFICATE' '-----END CERTIFICATE-----' >"$TARGET_DIR/privkeys/$name"
  "$REAL_CHMOD" 644 "$TARGET_DIR/privkeys/$name"
done
make_file "$TARGET_DIR/privkeys/server.key" 644
_ensure_tls_permissions "$TARGET_DIR/privkeys/helper-public.pem"
assert_mode "$TARGET_DIR/privkeys/helper-public.pem" 640 'public PEM TLS helper in privkeys directory'
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$TARGET_DIR/privkeys/certificate.pem" 644 'public PEM repair in privkeys directory'
assert_mode "$TARGET_DIR/privkeys/server.key" 600 'recognized key within privkeys directory'

# Arbitrarily named PEM files can contain private keys or combined key/cert
# material. Recognize the marker without depending on the filename or printing
# any body bytes. The data is deliberately a nonfunctional dummy fixture.
reset_fixture pem-content
for kind in RSA EC DSA ENCRYPTED OPENSSH generic; do
  file="$TARGET_DIR/custom-$kind.pem"
  marker="$kind PRIVATE KEY"
  [ "$kind" != generic ] || marker='PRIVATE KEY'
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'DUMMY_PUBLIC_CERTIFICATE' '-----END CERTIFICATE-----' \
    "-----BEGIN $marker-----" 'DUMMY_PEM_BODY_MUST_NOT_BE_LOGGED' "-----END $marker-----" >"$file"
  "$REAL_CHMOD" 644 "$file"
done
make_file "$TARGET_DIR/certificate.pem" 644
output="$(fix_permissions "$TARGET_DIR" 2>&1)"
for kind in RSA EC DSA ENCRYPTED OPENSSH generic; do
  assert_mode "$TARGET_DIR/custom-$kind.pem" 600 "PEM content marker $kind"
done
assert_mode "$TARGET_DIR/certificate.pem" 644 'ordinary PEM remains public'
case "$output" in
*DUMMY_PEM_BODY_MUST_NOT_BE_LOGGED*) fail_check 'repair printed private PEM contents' ;;
esac

# A failed PEM inspection is not evidence that a file is public. The error
# must abort the whole repair preflight, before any ownership/mode mutation.
reset_fixture pem-read-error
make_file "$TARGET_DIR/ambiguous.pem" 644
FAIL_GREP_TARGET="$TARGET_DIR/ambiguous.pem"
: >"$CHMOD_TRACE"
: >"$CHOWN_TRACE"
expect_repair_failure 'PEM read error'
[ ! -s "$CHMOD_TRACE" ] || fail_check 'PEM read error was discovered after chmod'
[ ! -s "$CHOWN_TRACE" ] || fail_check 'PEM read error was discovered after chown'
if _ensure_tls_permissions "$TARGET_DIR/ambiguous.pem" >/dev/null 2>&1; then
  fail_check 'TLS helper ignored PEM read error'
fi
assert_mode "$TARGET_DIR/ambiguous.pem" 644 'failed PEM inspection leaves mode intact'

# A permission ceiling removes excess access; it must never add a previously
# absent owner or group bit, even when fixing a special-bit or unreadable file.
reset_fixture restrictive
# Non-root macOS cannot set sticky bits on regular files; cover those on the
# directory fixtures below, and exercise both set-ID bits on these key files.
for original_mode in 2600 4600 6600; do
  file="$TARGET_DIR/special-$original_mode.key"
  make_file "$file" "$original_mode"
  assert_mode "$file" "$original_mode" 'special-bit fixture is present before inspection'
  observed_mode="$(_portable_stat_mode "$file")"
  [ "$observed_mode" = "$original_mode" ] || fail_check "mode helper omitted special bits from $original_mode"
  _permissions_metadata_stat "$file" || fail_check "metadata helper could not inspect $original_mode"
  [ "$PERMISSIONS_STAT_MODE" = "$original_mode" ] || fail_check "metadata helper omitted special bits from $original_mode"
  _ensure_tls_permissions "$file"
  assert_mode "$file" 600 "helper removes all special bits from $original_mode"
done
# Reject malformed or over-wide full BSD modes instead of masking arbitrary
# output into apparently valid access bits. Each probe has its own stat shim.
for invalid_mode in '' not-octal 104888 200000 10000000 '104600 extra'; do
  if ! (
    function stat() {
      [ "${1:-}" = -f ] || return 1
      case "${2:-}" in
      %p) printf '%s\n' "$invalid_mode" ;;
      '%d %i %u %g %p %l') printf '1 2 0 0 %s 1\n' "$invalid_mode" ;;
      *) return 1 ;;
      esac
    }
    if _portable_stat_mode "$file" >/dev/null; then exit 1; fi
    if _permissions_metadata_stat "$file"; then exit 1; fi
  ); then
    fail_check 'permission mode helper accepted malformed full BSD stat output'
  fi
done
for original_mode in 0 200 400 600 640 644 700 777 4600; do
  file="$TARGET_DIR/mode-$original_mode.key"
  make_file "$file" "$original_mode"
  _ensure_tls_permissions "$file"
  case "$original_mode" in
  0) expected=0 ;;
  200) expected=200 ;;
  400) expected=400 ;;
  *) expected=600 ;;
  esac
  assert_mode "$file" "$expected" "helper restrictive mode $original_mode"
done
make_file "$TARGET_DIR/readonly.key" 400
make_file "$TARGET_DIR/writeonly.p12" 200
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$TARGET_DIR/readonly.key" 400 'repair preserves read-only key'
assert_mode "$TARGET_DIR/writeonly.p12" 200 'repair preserves write-only bundle'

# Directories can carry set-ID and sticky bits. GNU chmod requires an explicit leading
# zero to clear these bits; both normal and private policies must apply exactly
# and preserve the original bits if a later file mutation fails.
for policy in ordinary private; do
  for outcome in success rollback; do
    reset_fixture "special-directory-$policy-$outcome"
    expected_directory_mode=750
    if [ "$policy" = private ]; then
      TARGET_DIR="$BACKUP_DIR/extracted"
      mkdir -p "$TARGET_DIR"
      expected_directory_mode=700
    fi
    mkdir "$TARGET_DIR/nested"
    make_file "$TARGET_DIR/failure.key" 644
    for directory in "$TARGET_DIR" "$TARGET_DIR/nested"; do
      "$REAL_CHGRP" "$TEST_PRIMARY_GID" "$directory"
      "$REAL_CHMOD" 03750 "$directory"
      assert_mode "$directory" 3750 "$policy directory special-bit fixture"
      _permissions_metadata_stat "$directory" || fail_check 'cannot inspect directory fixture group'
      [ "$PERMISSIONS_STAT_GID" = "$TEST_PRIMARY_GID" ] || fail_check 'directory fixture is not in the primary group'
    done
    if [ "$outcome" = rollback ]; then
      PARTIAL_CHMOD_TARGET="$TARGET_DIR/failure.key"
      expect_repair_failure "$policy special directory rollback"
      expected_directory_mode=3750
      expected_key_mode=644
    else
      if ! fix_permissions "$TARGET_DIR" >/dev/null; then
        fail_check "$policy special directory repair failed"
      fi
      expected_key_mode=600
    fi
    assert_mode "$TARGET_DIR" "$expected_directory_mode" "$policy directory $outcome root mode"
    assert_mode "$TARGET_DIR/nested" "$expected_directory_mode" "$policy directory $outcome nested mode"
    assert_mode "$TARGET_DIR/failure.key" "$expected_key_mode" "$policy directory $outcome key mode"
  done
done

# Repairing an unrelated target must not chmod scripts or state in BASE_DIR,
# create missing runtime directories there, or repair an unrelated active key.
reset_fixture scope
make_file "$BASE_DIR/dockistrate.sh" 600
make_file "$GLOBAL_SETTINGS_FILE" 666
make_file "$LOG_FILE" 644
make_file "$CERTS_DIR/live.key" 644
make_file "$TARGET_DIR/local.key" 644
"$REAL_CHMOD" 700 "$STATE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CERTS_DIR"
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$TARGET_DIR/local.key" 600 'scoped target key'
assert_mode "$BASE_DIR/dockistrate.sh" 600 'unrelated active entrypoint'
assert_mode "$GLOBAL_SETTINGS_FILE" 666 'unrelated global settings'
assert_mode "$LOG_FILE" 644 'unrelated operator log'
assert_mode "$CERTS_DIR/live.key" 644 'unrelated active key'
for dir in "$STATE_DIR" "$CONFIG_DIR" "$LOG_DIR" "$CERTS_DIR"; do
  assert_mode "$dir" 700 'unrelated active directory'
done
[ ! -e "$TMP_DIR" ] || fail_check 'scoped repair created unrelated tmp directory'
[ ! -e "$BACKUP_DIR" ] || fail_check 'scoped repair created unrelated backup directory'
[ ! -e "$CAPTURE_DIR" ] || fail_check 'scoped repair created unrelated capture directory'

# Runtime policy still applies when the chosen target is a descendant of a
# configured private tree, while the ancestor itself remains outside the scope.
reset_fixture private-descendant
TARGET_DIR="$BACKUP_DIR/extracted"
mkdir -p "$TARGET_DIR/nested"
"$REAL_CHMOD" 777 "$BACKUP_DIR" "$TARGET_DIR" "$TARGET_DIR/nested"
make_file "$TARGET_DIR/nested/configuration.csv" 666
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$BACKUP_DIR" 777 'unselected backup ancestor'
assert_mode "$TARGET_DIR" 700 'selected backup subtree root'
assert_mode "$TARGET_DIR/nested" 700 'selected backup nested directory'
assert_mode "$TARGET_DIR/nested/configuration.csv" 600 'selected backup secret copy'

reset_fixture certificate-descendant
TARGET_DIR="$CERTS_DIR/alternate"
mkdir -p "$TARGET_DIR/nested"
"$REAL_CHMOD" 777 "$CERTS_DIR" "$TARGET_DIR" "$TARGET_DIR/nested"
make_file "$TARGET_DIR/nested/server.key" 644
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$CERTS_DIR" 777 'unselected certificate ancestor'
assert_mode "$TARGET_DIR" 750 'selected certificate subtree root'
assert_mode "$TARGET_DIR/nested" 750 'selected certificate nested directory'
assert_mode "$TARGET_DIR/nested/server.key" 600 'selected certificate key'

# Configured directory aliases outside BASE_DIR may resolve to a physical
# runtime directory inside the selected target. Keep its runtime boundary mode.
reset_fixture runtime-aliases
physical_config="$CONFIG_DIR"
physical_certs="$CERTS_DIR"
ln -s "$physical_config" "$TEST_DIR/config-alias"
ln -s "$physical_certs" "$TEST_DIR/certs-alias"
CONFIG_DIR="$TEST_DIR/config-alias"
CERTS_DIR="$TEST_DIR/certs-alias"
make_file "$physical_certs/custom.key" 644
"$REAL_CHMOD" 777 "$physical_config" "$physical_certs"
fix_permissions "$BASE_DIR" >/dev/null
assert_mode "$physical_config" 750 'aliased config runtime boundary'
assert_mode "$physical_certs" 750 'aliased certificate runtime boundary'
assert_mode "$physical_certs/custom.key" 600 'aliased certificate key'

# Real Certbot live entries are symlinks to archive files. Keep the entries and
# repair the physical archive once. Symlinks out of the selected tree stay inert.
reset_fixture links
mkdir -p "$TARGET_DIR/letsencrypt/live/example.com" "$TARGET_DIR/letsencrypt/archive/example.com"
archive_key="$TARGET_DIR/letsencrypt/archive/example.com/privkey1.pem"
make_file "$archive_key" 644
ln -s ../../archive/example.com/privkey1.pem "$TARGET_DIR/letsencrypt/live/example.com/privkey.pem"
make_file "$TEST_DIR/outside.key" 644
mkdir "$TEST_DIR/outside-directory"
make_file "$TEST_DIR/outside-directory/nested.key" 644
ln -s "$TEST_DIR/outside.key" "$TARGET_DIR/escape.key"
ln -s "$TEST_DIR/outside-directory" "$TARGET_DIR/escape-directory"
fix_permissions "$TARGET_DIR" >/dev/null
assert_mode "$archive_key" 600 'Certbot physical archive key'
[ -L "$TARGET_DIR/letsencrypt/live/example.com/privkey.pem" ] || fail_check 'repair replaced Certbot symlink'
assert_mode "$TEST_DIR/outside.key" 644 'external symlink target'
assert_mode "$TEST_DIR/outside-directory/nested.key" 644 'external symlink directory'

# A hardlink changes the same inode outside the requested repair tree. Reject
# the entire tree before changing ownership or permissions of any entry.
reset_fixture hardlink
make_file "$TEST_DIR/hardlink-outside.key" 644
ln "$TEST_DIR/hardlink-outside.key" "$TARGET_DIR/linked.key"
make_file "$TARGET_DIR/ordinary.txt" 600
: >"$CHMOD_TRACE"
: >"$CHOWN_TRACE"
expect_repair_failure 'hardlinked key'
[ ! -s "$CHMOD_TRACE" ] || fail_check 'hardlink rejected after chmod mutation'
[ ! -s "$CHOWN_TRACE" ] || fail_check 'hardlink rejected after chown mutation'
assert_mode "$TEST_DIR/hardlink-outside.key" 644 'hardlink external target'
assert_mode "$TARGET_DIR/ordinary.txt" 600 'hardlink preflight ordinary sibling'

# Test both failing and success-without-effect chmod implementations. Running
# as root cannot otherwise reliably reproduce access-denied filesystem errors.
for failure in fail noop; do
  reset_fixture "chmod-$failure"
  file="$TARGET_DIR/failure.key"
  make_file "$file" 644
  case "$failure" in
  fail) FAIL_CHMOD_TARGET="$file" ;;
  noop) NOOP_CHMOD_TARGET="$file" ;;
  esac
  if _ensure_tls_permissions "$file" >/dev/null 2>&1; then
    fail_check "$failure chmod: TLS helper reported success"
  fi
  expect_repair_failure "$failure chmod key"
  assert_mode "$file" 644 "$failure chmod keeps actual fixture mode"
done
reset_fixture directory-failure
make_file "$TARGET_DIR/private.key" 600
"$REAL_CHMOD" 777 "$TARGET_DIR"
FAIL_CHMOD_TARGET="$TARGET_DIR"
expect_repair_failure 'directory chmod failure'


# Filesystem failures must restore metadata changed earlier in the repair. A
# failing chmod may already have changed its own target before returning error.
reset_fixture rollback
make_file "$TARGET_DIR/ordinary.txt" 666
make_file "$TARGET_DIR/failure.key" 644
"$REAL_CHMOD" 777 "$TARGET_DIR"
PARTIAL_CHMOD_TARGET="$TARGET_DIR/failure.key"
expect_repair_failure 'partially applied chmod'
[ -e "$PARTIAL_CHMOD_ONCE" ] || fail_check 'partial chmod failure was not exercised'
assert_mode "$TARGET_DIR" 777 'rollback restores earlier directory mode'
assert_mode "$TARGET_DIR/ordinary.txt" 666 'rollback restores earlier file mode'
assert_mode "$TARGET_DIR/failure.key" 644 'rollback restores partially changed target'

# Interrupt the actual repair subprocess after chmod changes its target. Its
# TERM trap must restore prior metadata without replacing the caller's traps.
reset_fixture interrupted
make_file "$TARGET_DIR/ordinary.txt" 666
make_file "$TARGET_DIR/interrupted.key" 644
"$REAL_CHMOD" 777 "$TARGET_DIR"
SIGNAL_CHMOD_TARGET="$TARGET_DIR/interrupted.key"
traps_before="$(trap -p EXIT HUP INT TERM)"
expect_repair_failure 'interrupted permission repair'
[ -e "$SIGNAL_CHMOD_ONCE" ] || fail_check 'TERM interruption was not exercised'
assert_mode "$TARGET_DIR" 777 'interrupted repair restores directory mode'
assert_mode "$TARGET_DIR/ordinary.txt" 666 'interrupted repair restores earlier file mode'
assert_mode "$TARGET_DIR/interrupted.key" 644 'interrupted repair restores last changed key'
[ "$(trap -p EXIT HUP INT TERM)" = "$traps_before" ] || fail_check 'repair changed caller signal/exit traps'

# If the filesystem also rejects rollback, report incomplete recovery instead
# of claiming that the original modes were restored.
reset_fixture rollback-failure
make_file "$TARGET_DIR/failure.key" 644
PARTIAL_CHMOD_TARGET="$TARGET_DIR/failure.key"
ROLLBACK_FAIL_TARGET="$TARGET_DIR/failure.key"
output=""
if output="$(fix_permissions "$TARGET_DIR" 2>&1)"; then
  fail_check 'failed rollback reported success'
fi
case "$output" in
*'[Error]'*'rollback'* | *'[Error]'*'restore'*) ;;
*) fail_check 'failed rollback did not report incomplete recovery' ;;
esac


# Ownership failures are portable to unprivileged test runners: the transaction
# requests a different UID while shims fail before performing a real chown.
# Cleared set-ID bits without the requested owner change are unattributed and
# must be preserved rather than blindly restored by rollback.
# Metadata transaction helpers are already loaded above.
# shellcheck source=../lib/backups/begin_transaction.sh
source "$ROOT_DIR/lib/backups/begin_transaction.sh"
# shellcheck source=../lib/backups/end_transaction_success.sh
source "$ROOT_DIR/lib/backups/end_transaction_success.sh"
function attempt_ownership_transaction() (
  local uid="" gid=""
  uid="$(id -u)"
  gid="$(id -g)"
  local -a PERMISSIONS_PLAN_PATHS=("$TARGET_DIR" "$TARGET_DIR/owner.key")
  local -a PERMISSIONS_PLAN_MODES=(755 600)
  local -a PERMISSIONS_PLAN_UIDS=("$uid" "$((uid + 1))")
  local -a PERMISSIONS_PLAN_GIDS=("$gid" "$gid")
  begin_transaction --permissions "$TARGET_DIR" || return 1
  if ! _permissions_transaction_apply; then
    _permissions_transaction_rollback || true
    return 1
  fi
  end_transaction_success --permissions
)
for failure in fail noop partial; do
  reset_fixture "chown-$failure"
  original_mode=644
  [ "$failure" != partial ] || original_mode=4644
  make_file "$TARGET_DIR/owner.key" "$original_mode"
  "$REAL_CHMOD" 700 "$TARGET_DIR"
  case "$failure" in
  fail) FAIL_CHOWN_TARGET="$TARGET_DIR/owner.key" ;;
  noop) NOOP_CHOWN_TARGET="$TARGET_DIR/owner.key" ;;
  partial) PARTIAL_CHOWN_TARGET="$TARGET_DIR/owner.key" ;;
  esac
  output=""
  if output="$(attempt_ownership_transaction 2>&1)"; then
    fail_check "$failure chown: transaction reported success"
  fi
  [ -s "$CHOWN_TRACE" ] || fail_check "$failure chown case did not exercise chown"
  assert_mode "$TARGET_DIR" 700 "$failure chown rollback restores prior directory"
  assert_mode "$TARGET_DIR/owner.key" 644 "$failure chown resulting key mode"
  if [ "$failure" = partial ]; then
    case "$output" in
    *'metadata rollback is incomplete'*) ;;
    *) fail_check 'partial chown without requested ownership did not report incomplete rollback' ;;
    esac
  fi
done

# Privileged runners can also exercise a real requested owner change followed
# by utility failure. This known state must restore the original UID and mode.
if [ "$(id -u)" -eq 0 ]; then
  reset_fixture requested-owner-partial
  make_file "$TARGET_DIR/owner.key" 4644
  "$REAL_CHMOD" 700 "$TARGET_DIR"
  PARTIAL_CHOWN_TARGET="$TARGET_DIR/owner.key"
  PARTIAL_CHOWN_APPLY=true
  output=""
  if output="$(attempt_ownership_transaction 2>&1)"; then
    fail_check 'requested owner change followed by failure reported success'
  fi
  [ -e "$PARTIAL_CHOWN_ONCE" ] || fail_check 'requested partial owner change was not exercised'
  _permissions_metadata_stat "$TARGET_DIR/owner.key" || fail_check 'cannot inspect restored owner'
  [ "$PERMISSIONS_STAT_UID" = 0 ] || fail_check 'requested partial owner change did not restore original UID'
  assert_mode "$TARGET_DIR/owner.key" 4644 'requested partial owner change restores original set-ID bits'
  assert_mode "$TARGET_DIR" 700 'requested partial owner change restores earlier directory'
  case "$output" in
  *'metadata rollback is incomplete'*) fail_check 'requested partial owner change was incorrectly treated as unknown' ;;
  esac
fi

# An unexpected post-command mode cannot be safely attributed to the utility:
# it may be another actor's change. Preserve it and report incomplete recovery.
for operation in chmod chown; do
  reset_fixture "unknown-partial-$operation"
  "$REAL_CHMOD" 700 "$TARGET_DIR"
  make_file "$TARGET_DIR/owner.key" 644
  case "$operation" in
  chmod)
    PARTIAL_CHMOD_TARGET="$TARGET_DIR/owner.key"
    PARTIAL_CHMOD_MODE=200
    ;;
  chown)
    PARTIAL_CHOWN_TARGET="$TARGET_DIR/owner.key"
    PARTIAL_CHOWN_MODE=200
    ;;
  esac
  output=""
  if [ "$operation" = chmod ]; then
    if output="$(fix_permissions "$TARGET_DIR" 2>&1)"; then
      fail_check 'unknown partial chmod reported success'
    fi
  elif output="$(attempt_ownership_transaction 2>&1)"; then
    fail_check 'unknown partial chown reported success'
  fi
  assert_mode "$TARGET_DIR/owner.key" 200 "unknown partial $operation preserves unattributed mode"
  assert_mode "$TARGET_DIR" 700 "unknown partial $operation restores uncontested earlier entry"
  case "$output" in
  *'metadata rollback is incomplete'*) ;;
  *) fail_check "unknown partial $operation did not report incomplete rollback" ;;
  esac
done

# A later utility failure must not undo another actor's tightening of an entry
# that this repair already changed. An ordered plan makes this interleaving
# deterministic. Known partial effects are recoverable; unattributed set-ID
# removal must remain intact when the requested ownership did not take effect.
function attempt_concurrent_transaction() (
  local operation="$1" uid="" gid="" last_uid=""
  uid="$(id -u)"
  gid="$(id -g)"
  last_uid="$uid"
  [ "$operation" != chown ] || last_uid="$((uid + 1))"
  local -a PERMISSIONS_PLAN_PATHS=("$TARGET_DIR" "$TARGET_DIR/earlier.key" "$TARGET_DIR/failure.key")
  local -a PERMISSIONS_PLAN_MODES=(755 600 600)
  local -a PERMISSIONS_PLAN_UIDS=("$uid" "$uid" "$last_uid")
  local -a PERMISSIONS_PLAN_GIDS=("$gid" "$gid" "$gid")
  begin_transaction --permissions "$TARGET_DIR" || return 1
  if ! _permissions_transaction_apply; then
    _permissions_transaction_rollback || true
    return 1
  fi
  end_transaction_success --permissions
)
for operation in chmod chown; do
  for failure in fail partial; do
    reset_fixture "concurrent-$operation-$failure"
    make_file "$TARGET_DIR/earlier.key" 644
    original_mode=644
    [ "$operation-$failure" != chown-partial ] || original_mode=4644
    make_file "$TARGET_DIR/failure.key" "$original_mode"
    "$REAL_CHMOD" 777 "$TARGET_DIR"
    CONCURRENT_TRIGGER_TARGET="$TARGET_DIR/failure.key"
    CONCURRENT_CHANGED_TARGET="$TARGET_DIR/earlier.key"
    case "$operation-$failure" in
    chmod-fail) FAIL_CHMOD_TARGET="$CONCURRENT_TRIGGER_TARGET" ;;
    chmod-partial) PARTIAL_CHMOD_TARGET="$CONCURRENT_TRIGGER_TARGET" ;;
    chown-fail) FAIL_CHOWN_TARGET="$CONCURRENT_TRIGGER_TARGET" ;;
    chown-partial) PARTIAL_CHOWN_TARGET="$CONCURRENT_TRIGGER_TARGET" ;;
    esac
    output=""
    if output="$(attempt_concurrent_transaction "$operation" 2>&1)"; then
      fail_check "concurrent $operation $failure: transaction reported success"
    fi
    if [ -e "$CONCURRENT_CHANGE_ONCE" ]; then
      [ "$(cat "$CONCURRENT_CHANGE_ONCE")" = 600 ] || fail_check "concurrent $operation $failure did not follow an applied repair"
    else
      fail_check "concurrent $operation $failure was not exercised"
    fi
    assert_mode "$TARGET_DIR/earlier.key" 400 "concurrent $operation $failure preserves another actor's restriction"
    assert_mode "$TARGET_DIR/failure.key" 644 "concurrent $operation $failure resulting later-entry mode"
    assert_mode "$TARGET_DIR" 777 "concurrent $operation $failure restores uncontested earlier entry"
    case "$output" in
    *'metadata rollback is incomplete'*) ;;
    *) fail_check "concurrent $operation $failure did not report incomplete rollback" ;;
    esac
  done
done

# Inject TERM immediately before and after the first completion trap operation.
# Before disarming, interruption must roll back; once signals are ignored, the
# repair must finish successfully with its committed metadata intact.
function attempt_completion_signal_transaction() (
  local completion_point="$1" uid="" gid="" completion_armed=false
  uid="$(id -u)"
  gid="$(id -g)"
  local -a PERMISSIONS_PLAN_PATHS=("$TARGET_DIR/completion.key")
  local -a PERMISSIONS_PLAN_MODES=(600)
  local -a PERMISSIONS_PLAN_UIDS=("$uid")
  local -a PERMISSIONS_PLAN_GIDS=("$gid")
  function trap() {
    if [ "$completion_point" = before ] && [ "$completion_armed" = true ] && [ ! -e "$COMPLETION_SIGNAL_ONCE" ]; then
      : >"$COMPLETION_SIGNAL_ONCE"
      "$BASH" -c 'kill -TERM "$PPID"'
    fi
    builtin trap "$@"
    if [ "$completion_point" = after ] && [ "$completion_armed" = true ] && [ ! -e "$COMPLETION_SIGNAL_ONCE" ]; then
      : >"$COMPLETION_SIGNAL_ONCE"
      "$BASH" -c 'kill -TERM "$PPID"'
    fi
  }
  begin_transaction --permissions "$TARGET_DIR" || return 1
  if ! _permissions_transaction_apply; then
    _permissions_transaction_rollback || true
    return 1
  fi
  completion_armed=true
  end_transaction_success --permissions
)
for completion_point in before after; do
  reset_fixture "completion-signal-$completion_point"
  make_file "$TARGET_DIR/completion.key" 644
  COMPLETION_SIGNAL_ONCE="$TEST_DIR/completion-signal-$completion_point-once"
  completion_status=0
  traps_before="$(trap -p EXIT HUP INT TERM)"
  output="$(attempt_completion_signal_transaction "$completion_point" 2>&1)" || completion_status=$?
  LAST_REPAIR_OUTPUT="$output"
  [ -e "$COMPLETION_SIGNAL_ONCE" ] || fail_check "$completion_point completion TERM window was not exercised"
  if [ "$completion_status" -eq 0 ]; then
    [ "$completion_point" != before ] || fail_check 'completion ignored TERM before signals were disarmed'
    assert_mode "$TARGET_DIR/completion.key" 600 "$completion_point successful completion retains repaired mode"
  else
    [ "$completion_point" != after ] || fail_check 'completion failed after signals were disarmed'
    assert_mode "$TARGET_DIR/completion.key" 644 "$completion_point interrupted completion restores original mode"
  fi
  [ "$(trap -p EXIT HUP INT TERM)" = "$traps_before" ] || fail_check "$completion_point completion signal changed caller traps"
done

if [ "$FAILURES" -ne 0 ]; then
  printf '[Error] Private-key permission checks failed: %s\n' "$FAILURES" >&2
  exit 1
fi
printf '[tests] private_key_permissions.sh: PASS\n'
