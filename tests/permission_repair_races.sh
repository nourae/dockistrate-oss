#!/usr/bin/env bash
# Globals below are consumed by the sourced permission/restore helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"${BASH:-bash}" "$ROOT_DIR/tests/permission_metadata_io.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-permission-races.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
# shellcheck source=../lib/permissions/fix_permissions.sh
source "$ROOT_DIR/lib/permissions/fix_permissions.sh"
BASE_DIR="$TEST_DIR/unused"
eval "$(declare -f _permissions_metadata_mutate_fd | sed '1s/_permissions_metadata_mutate_fd/_real_metadata_mutate_fd/')"

# The transaction's post-guard boundary is deterministic. Both its forward
# operation and reverse recovery must refuse a substituted pathname.
function _permissions_metadata_mutate_fd() {
  local path="${PERMISSIONS_TXN_PATHS[$1]}"
  if [ "$path" = "$selected/first.key" ] && [ "$2" = chmod ] && [ "$3" = "$swap_mode" ]; then
    mv "$path" "$selected/original.key"
    ln -s "$outside" "$path"
  fi
  if [ "$path" = "$selected/second.key" ]; then return 1; fi
  _real_metadata_mutate_fd "$@"
}

for phase in forward rollback; do
  selected="$TEST_DIR/$phase"
  outside="$TEST_DIR/$phase-sentinel.key"
  mkdir "$selected"
  printf 'fixture\n' >"$selected/first.key"
  printf 'external sentinel\n' >"$outside"
  chmod 644 "$selected/first.key" "$outside"
  swap_mode=600
  if [ "$phase" = rollback ]; then
    printf 'second fixture\n' >"$selected/second.key"
    chmod 644 "$selected/second.key"
    swap_mode=644
  fi
  if (
    if [ "$phase" = forward ]; then
      fix_permissions "$selected"
    else
      # Pin operation order independently of the filesystem's readdir order.
      PERMISSIONS_PLAN_PATHS=("$selected/first.key" "$selected/second.key")
      PERMISSIONS_PLAN_MODES=(600 600)
      PERMISSIONS_PLAN_UIDS=("$(command id -u)" "$(command id -u)")
      PERMISSIONS_PLAN_GIDS=("$(command id -g)" "$(command id -g)")
      begin_transaction --permissions "$selected" || exit 1
      if ! _permissions_transaction_apply; then
        _permissions_transaction_rollback || true
        exit 1
      fi
      end_transaction_success --permissions
    fi
  ) >"$TEST_DIR/$phase.log" 2>&1; then
    echo "[Error] $phase replacement incorrectly reported success." >&2
    exit 1
  fi
  [ -L "$selected/first.key" ] || { cat "$TEST_DIR/$phase.log" >&2; exit 1; }
  _permissions_metadata_stat "$outside"
  [ "$PERMISSIONS_STAT_MODE" = 644 ] || exit 1
  [ "$(cat "$outside")" = 'external sentinel' ] || exit 1
done

# The explicit Darwin workflow must use the same protected mutation boundary.
# Simulate its platform/sudo preconditions without requiring privileged CI.
selected="$TEST_DIR/darwin/certs/letsencrypt"
outside="$TEST_DIR/darwin-sentinel.key"
CERTS_DIR="${selected%/letsencrypt}"
ACME_WEBROOT_DIR="$TEST_DIR/darwin/acme"
SUDO_UID="$(command id -u)"
SUDO_GID="$(command id -g)"
mkdir -p "$selected" "$ACME_WEBROOT_DIR"
printf 'fixture\n' >"$selected/first.key"
printf 'external sentinel\n' >"$outside"
chmod 644 "$selected/first.key" "$outside"
swap_mode=600
function _fix_permissions_is_darwin_host() { return 0; }
function id() {
  if [ "${1:-}" = -u ]; then printf '0\n'; else command id "$@"; fi
}
if fix_permissions_certbot_darwin_user >"$TEST_DIR/darwin.log" 2>&1; then exit 1; fi
unset -f id
[ -L "$selected/first.key" ] || { cat "$TEST_DIR/darwin.log" >&2; exit 1; }
_permissions_metadata_stat "$outside"
[ "$PERMISSIONS_STAT_MODE" = 644 ] || exit 1

# Fresh Darwin roots must be traversable by the mapped user even when their
# state/certificate ancestors did not exist. Existing parents stay unchanged.
chmod 755 "$TEST_DIR"
SUDO_UID="$(command id -u)"
SUDO_GID="$(command id -g)"
if [ "$SUDO_UID" = 0 ]; then
  SUDO_UID="$(command id -u nobody)"
  SUDO_GID="$(command id -g nobody)"
fi
CERTS_DIR="$TEST_DIR/fresh/state/certs"
ACME_WEBROOT_DIR="$TEST_DIR/fresh/state/acme"
selected="$TEST_DIR/no-mutation-hook"
function id() {
  if [ "${1:-}" = -u ]; then printf '0\n'; else command id "$@"; fi
}
if ! fix_permissions_certbot_darwin_user >"$TEST_DIR/fresh-darwin.log" 2>&1; then
  cat "$TEST_DIR/fresh-darwin.log" >&2
  exit 1
fi
unset -f id
for path in "$TEST_DIR/fresh" "$TEST_DIR/fresh/state" "$CERTS_DIR" "$CERTS_DIR/letsencrypt" "$ACME_WEBROOT_DIR"; do
  _permissions_metadata_stat "$path"
  [ "$PERMISSIONS_STAT_MODE" = 750 ] && [ "$PERMISSIONS_STAT_UID" = "$SUDO_UID" ] &&
    [ "$PERMISSIONS_STAT_GID" = "$SUDO_GID" ] || exit 1
done
_permissions_metadata_stat "$TEST_DIR"
[ "$PERMISSIONS_STAT_MODE" = 755 ] && [ "$PERMISSIONS_STAT_UID" = "$(command id -u)" ] || exit 1
(
  # Pin the boundary before dropping privileges: runner workspaces themselves
  # may be below private ancestors. Native sudo retains this working directory;
  # physical cd keeps the probe relative instead of rebuilding a protected path.
  cd -- "$TEST_DIR"
  probe='for path in fresh/state/certs/letsencrypt fresh/state/acme; do (cd -P "$path" && [ -r . ] && [ -w . ] && [ -x . ]) || exit 1; done'
  if [ "$(command id -u)" = 0 ]; then
    sudo -u "#$SUDO_UID" -g "#$SUDO_GID" -- /bin/sh -c "$probe"
  else
    /bin/sh -c "$probe"
  fi
)

# Each mount entry is planned once, including either direction of nesting.
# TLS keys retain the tighter policy when also covered by the plain ACME tree.
SUDO_UID="$(command id -u)"
SUDO_GID="$(command id -g)"
function id() {
  if [ "${1:-}" = -u ]; then printf '0\n'; else command id "$@"; fi
}
for relation in disjoint acme-in-tls tls-in-acme equal; do
  CERTS_DIR="$TEST_DIR/$relation/certs"
  case "$relation" in
  disjoint) ACME_WEBROOT_DIR="$TEST_DIR/$relation/acme" ;;
  acme-in-tls) ACME_WEBROOT_DIR="$CERTS_DIR/letsencrypt/acme" ;;
  tls-in-acme) ACME_WEBROOT_DIR="$CERTS_DIR" ;;
  equal) ACME_WEBROOT_DIR="$CERTS_DIR/letsencrypt" ;;
  esac
  mkdir -p "$CERTS_DIR/letsencrypt" "$ACME_WEBROOT_DIR"
  printf 'fixture\n' >"$CERTS_DIR/letsencrypt/fixture.key"
  printf 'token\n' >"$ACME_WEBROOT_DIR/token.txt"
  chmod 644 "$CERTS_DIR/letsencrypt/fixture.key" "$ACME_WEBROOT_DIR/token.txt"
  if ! fix_permissions_certbot_darwin_user >"$TEST_DIR/$relation.log" 2>&1; then
    cat "$TEST_DIR/$relation.log" >&2
    exit 1
  fi
  _permissions_metadata_stat "$CERTS_DIR/letsencrypt/fixture.key"
  [ "$PERMISSIONS_STAT_MODE" = 600 ] || exit 1
  _permissions_metadata_stat "$ACME_WEBROOT_DIR/token.txt"
  [ "$PERMISSIONS_STAT_MODE" = 640 ] || exit 1
done
unset -f id

# Missing safe filesystem support must fail before staging or live changes.
# Source directly to cover callers that did not load all application modules.
# shellcheck source=../lib/backups/restore_backup.sh
source "$ROOT_DIR/lib/backups/restore_backup.sh"
function _permissions_metadata_require_helper() { return 1; }
function _restore_intake_limits() { :; }
function confirm_prompt() { return 0; }
mkdir "$TEST_DIR/backup"
TMP_DIR="$TEST_DIR/must-not-be-created"
if restore_backup "$TEST_DIR/backup" >"$TEST_DIR/restore.log" 2>&1; then exit 1; fi
[ ! -e "$TMP_DIR" ] || exit 1
echo 'Descriptor-bound permission repair and recovery checks passed.'
