#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_transaction_archive.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
REAL_TAR="$(command -v tar)"
ARCHIVE_LOCALE="$(_transaction_archive_locale)"
fixture="" archive="" stage=""

function new_fixture() {
  fixture="$TMP_ROOT/$1/source"
  archive="$TMP_ROOT/$1/archive.tar.gz"
  stage="$TMP_ROOT/$1/stage"
  mkdir -p "$fixture"
  mkdir -m 700 "$stage"
}

function make_archive() {
  (cd "$fixture" && LC_ALL="$ARCHIVE_LOCALE" COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
    "$REAL_TAR" -czf "$archive" -- "$@")
}

function expect_rejected() {
  if _safe_extract_transaction_tar "$archive" "$stage" >"$TMP_ROOT/$1.out" 2>&1; then
    printf '[Error] Unsafe transaction archive accepted: %s\n' "$1" >&2
    exit 1
  fi
  printf '[tests] PASS: transaction archive rejects %s\n' "$1"
}

function assert_mode() {
  local path="${1:-}" expected="${2:-}" actual=""
  if ! actual="$(stat -c '%a' "$path" 2>/dev/null)"; then
    actual="$(stat -f '%Lp' "$path")" || exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    printf '[Error] Expected mode %s, got %s: %s\n' "$expected" "$actual" "$path" >&2
    exit 1
  fi
}

new_fixture certbot
mkdir -p "$fixture/certs/archive/example.com" "$fixture/certs/live/example.com"
printf certificate >"$fixture/certs/archive/example.com/fullchain1.pem"
ln -s ../../archive/example.com/fullchain1.pem "$fixture/certs/live/example.com/fullchain.pem"
make_archive certs
_safe_extract_transaction_tar "$archive" "$stage"
[ "$(readlink "$stage/certs/live/example.com/fullchain.pem")" = ../../archive/example.com/fullchain1.pem ]
[ "$(cat "$stage/certs/live/example.com/fullchain.pem")" = certificate ]
_validate_transaction_backup_targets "$fixture" "$fixture/certs"
_validate_transaction_backup_targets "$fixture" "$fixture/certs/archive" "$fixture/certs/live"
if _validate_transaction_backup_targets "$fixture" "$fixture/certs/live" >"$TMP_ROOT/omitted-target.out" 2>&1; then
  echo '[Error] Producer accepted a symlink whose target was omitted.' >&2
  exit 1
fi
if _safe_extract_tar "$archive" "$TMP_ROOT/public-restore" >/dev/null 2>&1; then
  echo '[Error] Public restore unexpectedly accepted transaction symlinks.' >&2
  exit 1
fi
printf '[tests] PASS: Certbot links roundtrip only through transaction extraction\n'
expect_rejected nonempty_stage

new_fixture preserved_modes
mkdir "$fixture/config" "$fixture/certs"
printf config >"$fixture/config/settings.csv"
printf certificate >"$fixture/certs/fullchain.pem"
printf private-key-fixture >"$fixture/certs/privkey.pem"
chmod 640 "$fixture/config/settings.csv" "$fixture/certs/fullchain.pem"
chmod 600 "$fixture/certs/privkey.pem"
chmod 750 "$fixture/config" "$fixture/certs"
chmod 755 "$fixture"
make_archive .
old_umask="$(umask)"
_safe_extract_transaction_tar "$archive" "$stage" || exit 1
[ "$(umask)" = "$old_umask" ] || exit 1
assert_mode "$stage/config/settings.csv" 640
assert_mode "$stage/certs/fullchain.pem" 640
assert_mode "$stage/certs/privkey.pem" 600
assert_mode "$stage/config" 750
assert_mode "$stage/certs" 750
assert_mode "$stage" 700
printf '[tests] PASS: snapshot modes survive restrictive extraction while staging stays private\n'

for kind in absolute_link escaping_link dangling_link cycle newline_link; do
  new_fixture "$kind"
  printf contents >"$fixture/file"
  case "$kind" in
  absolute_link) ln -s / "$fixture/link" ;;
  escaping_link) ln -s ../outside "$fixture/link" ;;
  dangling_link) ln -s missing "$fixture/link" ;;
  cycle) ln -s other "$fixture/link"; ln -s link "$fixture/other" ;;
  newline_link) ln -s $'file\n' "$fixture/link" ;;
  esac
  make_archive .
  expect_rejected "$kind"
done

# Darwin readlink adds a delimiter only when the target does not already end in
# a newline. Emulate that behavior so Linux also catches accidental trimming of
# a target byte as if it were an output delimiter.
(
  # shellcheck disable=SC2329 # Called indirectly by the transaction validators.
  function readlink() {
    local no_delimiter=false target=""
    if [ "${1:-}" = -n ]; then no_delimiter=true; shift; fi
    target="$(command readlink -n "$@" && printf '.')" || return 1
    target="${target%.}"
    printf '%s' "$target"
    if [ "$no_delimiter" = false ] && [[ "$target" != *$'\n' ]]; then printf '\n'; fi
    return 0
  }

  new_fixture darwin_readlink_safe
  printf contents >"$fixture/file."
  ln -s file. "$fixture/link"
  make_archive .
  _safe_extract_transaction_tar "$archive" "$stage" || exit 1
  [ "$(cat "$stage/link")" = contents ] || exit 1
  _validate_transaction_backup_targets "$fixture" "$fixture" || exit 1
  printf '[tests] PASS: Darwin readlink preserves safe targets including a trailing dot\n'

  new_fixture darwin_newline_link
  printf contents >"$fixture/file"
  ln -s $'file\n' "$fixture/link"
  [ "$(readlink "$fixture/link" && printf '.')" = $'file\n.' ] || exit 1
  make_archive .
  expect_rejected darwin_newline_link
  if _validate_transaction_backup_targets "$fixture" "$fixture" >"$TMP_ROOT/producer-darwin-newline.out" 2>&1; then
    echo '[Error] Producer accepted a newline target with Darwin readlink output.' >&2
    exit 1
  fi
) || exit 1

new_fixture nested_escape
mkdir "$fixture/inside"
printf contents >"$fixture/inside/file"
ln -s ../../outside "$fixture/inside/escape"
ln -s inside/escape/file "$fixture/link"
make_archive .
expect_rejected nested_escape

new_fixture escape_and_reenter
mkdir "$fixture/inside"
printf contents >"$fixture/inside/file"
ln -s ../../source/inside/file "$fixture/inside/link"
make_archive .
expect_rejected escape_and_reenter

new_fixture directory_links
mkdir "$fixture/inside"
printf contents >"$fixture/inside/file"
ln -s inside "$fixture/directory"
ln -s directory/file "$fixture/link"
make_archive .
_safe_extract_transaction_tar "$archive" "$stage"
[ "$(cat "$stage/link")" = contents ]
printf '[tests] PASS: contained directory symlinks and chains roundtrip\n'

new_fixture pax_long_name
long_directory="$(printf '%0150d' 0)"
mkdir "$fixture/$long_directory"
printf contents >"$fixture/$long_directory/with spaces"
(cd "$fixture" && LC_ALL="$ARCHIVE_LOCALE" COPYFILE_DISABLE=1 COPY_EXTENDED_ATTRIBUTES_DISABLE=1 \
  "$REAL_TAR" --format=pax -czf "$archive" "$long_directory")
_safe_extract_transaction_tar "$archive" "$stage"
[ "$(cat "$stage/$long_directory/with spaces")" = contents ]
printf '[tests] PASS: PAX long paths and spaces roundtrip\n'

for kind in absolute_member parent_member; do
  new_fixture "$kind"
  mkdir "$TMP_ROOT/$kind/outside"
  printf attack >"$TMP_ROOT/$kind/outside/sentinel"
  if [ "$kind" = absolute_member ]; then
    "$REAL_TAR" -czPf "$archive" "$TMP_ROOT/$kind/outside/sentinel"
  else
    (cd "$fixture" && "$REAL_TAR" -czPf "$archive" ../outside/sentinel)
  fi
  printf sentinel >"$TMP_ROOT/$kind/outside/sentinel"
  expect_rejected "$kind"
  [ "$(cat "$TMP_ROOT/$kind/outside/sentinel")" = sentinel ]
done

for kind in symlink_ancestor symlink_ancestor_reversed; do
  new_fixture "$kind"
  mkdir "$TMP_ROOT/$kind/outside"
  printf attack >"$TMP_ROOT/$kind/outside/sentinel"
  ln -s ../outside "$fixture/link"
  if [ "$kind" = symlink_ancestor ]; then
    (cd "$fixture" && "$REAL_TAR" -cf "$archive.raw" link && "$REAL_TAR" -rf "$archive.raw" link/sentinel)
  else
    (cd "$fixture" && "$REAL_TAR" -cf "$archive.raw" link/sentinel && "$REAL_TAR" -rf "$archive.raw" link)
  fi
  gzip -c "$archive.raw" >"$archive"
  printf sentinel >"$TMP_ROOT/$kind/outside/sentinel"
  expect_rejected "$kind"
  [ "$(cat "$TMP_ROOT/$kind/outside/sentinel")" = sentinel ]
  [ -z "$(find "$stage" -mindepth 1 -print -quit)" ]
done

for kind in duplicate duplicate_alias; do
  new_fixture "$kind"
  printf first >"$fixture/file"
  (cd "$fixture" && "$REAL_TAR" -cf "$archive.raw" file)
  printf second >"$fixture/file"
  member="file"
  [ "$kind" != duplicate_alias ] || member=./file
  (cd "$fixture" && "$REAL_TAR" -rf "$archive.raw" "$member")
  gzip -c "$archive.raw" >"$archive"
  expect_rejected "$kind"
done

for kind in hardlink fifo newline_member; do
  new_fixture "$kind"
  printf contents >"$fixture/file"
  case "$kind" in
  hardlink) ln "$fixture/file" "$fixture/hardlink" ;;
  fifo) mkfifo "$fixture/fifo" ;;
  newline_member) printf invalid >"$fixture/"$'unsafe\nname' ;;
  esac
  make_archive .
  expect_rejected "$kind"
  if _validate_transaction_backup_targets "$fixture" "$fixture" >"$TMP_ROOT/producer-$kind.out" 2>&1; then
    printf '[Error] Producer accepted unsupported entry: %s\n' "$kind" >&2
    exit 1
  fi
done

new_fixture omitted_intermediate
mkdir "$fixture/selected" "$fixture/omitted"
printf contents >"$fixture/selected/file"
ln -s ../selected/file "$fixture/omitted/chain"
ln -s ../omitted/chain "$fixture/selected/link"
if _validate_transaction_backup_targets "$fixture" "$fixture/selected" >/dev/null 2>&1; then
  echo '[Error] Producer accepted an omitted intermediate symlink.' >&2
  exit 1
fi
rm "$fixture/selected/link"
ln -s ../omitted/../selected/file "$fixture/selected/link"
if _validate_transaction_backup_targets "$fixture" "$fixture/selected" >/dev/null 2>&1; then
  echo '[Error] Producer accepted an omitted intermediate directory.' >&2
  exit 1
fi
printf '[tests] PASS: producer rejects missing intermediate link dependencies\n'

new_fixture corrupt
printf 'not a gzip archive' >"$archive"
expect_rejected corrupt

# A command that emits plausible partial output but fails must never reach the
# extraction operation. A failed extraction must also restore the caller umask.
new_fixture listing_failure
printf placeholder >"$archive"
for fail_listing in names details extraction; do
  (
    # shellcheck disable=SC2329 # Called indirectly by the extraction helper.
    function tar() {
      case "${1:-}" in
      --version) printf 'tar (GNU tar) 1.35\n' ;;
      -tzf) printf 'file\n'; [ "$fail_listing" != names ] ;;
      -tzvf) printf '%s\n' '-rw------- 0/0 4 1970-01-01 00:00 file'; [ "$fail_listing" != details ] ;;
      -xzf) : >"$TMP_ROOT/extraction-called"; chmod 755 "$stage"; return 1 ;;
      *) return 1 ;;
      esac
    }
    old_umask="$(umask)"
    expect_rejected "failed_$fail_listing"
    [ "$(umask)" = "$old_umask" ] || exit 1
    if [ "$fail_listing" = extraction ]; then
      [ -f "$TMP_ROOT/extraction-called" ] || exit 1
      assert_mode "$stage" 700
    else
      [ ! -e "$TMP_ROOT/extraction-called" ] || exit 1
    fi
  ) || exit 1
done

new_fixture find_failure
(
  # shellcheck disable=SC2329 # Called indirectly by the tree validator.
  function find() { return 1; }
  if _validate_transaction_tree_safe "$stage"; then
    echo '[Error] Failed tree traversal was accepted.' >&2
    exit 1
  fi
)
printf '[tests] PASS: failed tree enumeration rejects validation\n'

# Exercise the actual producer, including BSD's empty-directory fallback and
# Unicode PAX handling when the invoking environment has the C locale.
BASE_DIR="$TMP_ROOT/producer"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
BACKUP_DIR="$STATE_DIR/backups"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
mkdir -p "$CONFIG_DIR" "$BACKUP_DIR" "$TMP_DIR" "$ERROR_LOG_DIR"
archive="$(backup_files_only missing "$CONFIG_DIR/absent.conf")"
stage="$TMP_ROOT/missing-stage"
mkdir -m 700 "$stage"
_safe_extract_transaction_tar "$archive" "$stage"
[ -z "$(find "$stage" -mindepth 1 -print -quit)" ]
printf '[tests] PASS: all-missing producer targets roundtrip as an empty archive\n'

if [ "$ARCHIVE_LOCALE" != C ]; then
  printf unicode >"$CONFIG_DIR/café.conf"
  ln -s café.conf "$CONFIG_DIR/cert-é.conf"
  if ! archive="$(LC_ALL=C backup_files_only unicode "$CONFIG_DIR")"; then
    echo '[Error] Unicode transaction backup creation failed.' >&2
    exit 1
  fi
  stage="$TMP_ROOT/unicode-stage"
  mkdir -m 700 "$stage"
  if ! LC_ALL=C _safe_extract_transaction_tar "$archive" "$stage"; then
    echo '[Error] Unicode transaction extraction failed.' >&2
    exit 1
  fi
  # Apple libarchive normalizes PAX link targets to decomposed Unicode. Check
  # filesystem identity instead of requiring the original UTF-8 byte spelling.
  if [ ! -L "$stage/config/cert-é.conf" ] ||
    [ ! "$stage/config/cert-é.conf" -ef "$stage/config/café.conf" ] ||
    [ "$(cat "$stage/config/cert-é.conf")" != unicode ]; then
    echo '[Error] Unicode symlink did not retain its expected target and content.' >&2
    exit 1
  fi
  printf '[tests] PASS: Unicode producer and symlink roundtrip in the C locale\n'
else
  printf '[tests] SKIP: Unicode roundtrip requires an installed UTF-8 locale\n'
fi
