#!/usr/bin/env bash
# shellcheck disable=SC2034 # Runtime settings are consumed by sourced functions.
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-restore-intake.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
PYTHON="$(command -v python3 || command -v python || true)"
if [ -z "$PYTHON" ] || ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info[0] != 3)'; then
  printf '[Error] Python 3 is required to generate restore intake test fixtures.\n' >&2
  exit 1
fi
BASE_DIR="$TEST_DIR/runtime"
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
TMP_DIR="$STATE_DIR/tmp"
BACKUP_DIR="$STATE_DIR/backups"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
SKIP_DOCKER_CHECKS=true
TRACE="$TEST_DIR/trace"
OUTPUT="$TEST_DIR/output"
CONFIRM=true
PASSED=0
SELECTION="${DOCKISTRATE_RESTORE_INTAKE_TEST_CASE:-all}"
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$ERROR_LOG_DIR" "$TEST_DIR/fixtures"
printf 'live configuration\n' >"$CONFIG_DIR/marker"
printf 'live log\n' >"$LOG_DIR/marker"
chmod 640 "$CONFIG_DIR/marker"

# Fixtures stay small even when their declared logical size exceeds a budget.
# Python is already a test dependency; the application does not depend on it.
"$PYTHON" - "$TEST_DIR/fixtures" <<'PY'
import gzip
import io
import os
import sys
import tarfile
import zipfile

root = sys.argv[1]
payload = b"restored configuration\n"

def archive(entries, fmt=tarfile.USTAR_FORMAT):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=fmt) as handle:
        for name, data in entries:
            entry = tarfile.TarInfo(name)
            entry.mode = 0o700 if data is None else 0o600
            if data is None:
                entry.type = tarfile.DIRTYPE
                handle.addfile(entry)
            else:
                entry.size = len(data)
                handle.addfile(entry, io.BytesIO(data))
    return output.getvalue()

def write(name, raw):
    data = gzip.compress(raw, mtime=0)
    with open(os.path.join(root, name + ".tar.gz"), "wb") as handle:
        handle.write(data)
    return len(data), len(raw)

raw = archive([("backup", None), ("backup/config", None), ("backup/config/marker", payload)])
compressed_size, expanded_size = write("safe", raw)
write("gnu-header", archive([("backup", None), ("backup/config", None),
                              ("backup/config/marker", payload)], tarfile.GNU_FORMAT))
legacy = bytearray(raw)
for offset in (0, 512, 1024):
    legacy[offset + 257:offset + 512] = b"\0" * 255
    legacy[offset + 148:offset + 156] = b"        "
    checksum = sum(legacy[offset:offset + 512])
    legacy[offset + 148:offset + 156] = ("%06o\0 " % checksum).encode("ascii")
write("v7-header", bytes(legacy))
bad_header = bytearray(raw)
bad_header[0] ^= 1
write("bad-header", bytes(bad_header))
# GNU tar and libarchive automatically inspect nested compression. The raw
# stream budget must not be bypassed by passing either library an inner codec.
write("double-gzip", gzip.compress(raw + b"\0" * 65536, mtime=0))
write("padded", raw + b"\0" * 65536)
write("concatenated", raw + archive([("backup/config/second", payload)]))
write("concatenated-duplicate", raw + raw)
zip_buffer = io.BytesIO()
with zipfile.ZipFile(zip_buffer, "w", compression=zipfile.ZIP_DEFLATED) as handle:
    handle.writestr("backup/config/marker", payload)
write("gzip-zip", zip_buffer.getvalue())
write("many", archive([("backup", None), ("backup/config", None)] +
                      [("backup/config/empty-%s" % index, b"") for index in range(6)]))
write("implicit-parents", archive([("backup/config/deeper/marker", payload)]))
with open(os.path.join(root, "trailing.tar.gz"), "wb") as handle:
    handle.write(gzip.compress(raw, mtime=0))
    handle.write(gzip.compress(b"\0" * 4096, mtime=0))
with open(os.path.join(root, "corrupt.tar.gz"), "wb") as handle:
    data = bytearray(gzip.compress(raw, mtime=0))
    data[-8] ^= 1  # A complete-looking stream with a bad CRC must fail closed.
    handle.write(data)
with open(os.path.join(root, "truncated.tar.gz"), "wb") as handle:
    handle.write(gzip.compress(raw, mtime=0)[:-5])

# PAX metadata can dominate expansion while regular-file payload stays tiny.
metadata = io.BytesIO()
with tarfile.open(fileobj=metadata, mode="w", format=tarfile.PAX_FORMAT) as handle:
    for name in ("backup", "backup/config"):
        entry = tarfile.TarInfo(name)
        entry.type = tarfile.DIRTYPE
        handle.addfile(entry)
    entry = tarfile.TarInfo("backup/config/marker")
    entry.size = len(payload)
    entry.pax_headers = {"comment": "m" * 20000}
    handle.addfile(entry, io.BytesIO(payload))
write("metadata", metadata.getvalue())
long_name = "long-name-" * 15
write("long-name", archive([("backup", None), ("backup/config", None),
                             ("backup/config/" + long_name, payload)], tarfile.PAX_FORMAT))

# Old GNU sparse format carries one real byte but declares a 1 MiB file.
# Tar listings expose its logical size; a raw-stream-only budget misses it.
sparse = tarfile.TarInfo("backup/config/sparse")
sparse.type = tarfile.GNUTYPE_SPARSE
sparse.mode = 0o600
sparse.size = 1
header = bytearray(sparse.tobuf(tarfile.GNU_FORMAT))
header[386:398] = b"00000000000\0"
header[398:410] = b"00000000001\0"
header[482] = 0
header[483:495] = b"00004000000\0"
header[148:156] = b"        "
header[148:156] = ("%06o\0 " % sum(header)).encode("ascii")
prefix = raw[:1024]  # The two parent directory headers have no bodies.
sparse_raw = prefix + bytes(header) + b"x" + b"\0" * 511 + b"\0" * 1024
write("sparse", sparse_raw)
second_header = bytearray(header)
second_name = b"backup/config/sparse-second"
second_header[:100] = second_name.ljust(100, b"\0")
second_header[148:156] = b"        "
second_header[148:156] = ("%06o\0 " % sum(second_header)).encode("ascii")
write("sparse-sum", sparse_raw[:-1024] + bytes(second_header) + b"x" + b"\0" * 1535)

write("rollback", archive([("config", None), ("config/marker", payload)]))
write("empty", archive([]))
write("multiple-roots", archive([("first", None), ("second", None)]))
directory = os.path.join(root, "directory")
os.makedirs(os.path.join(directory, "config"))
with open(os.path.join(directory, "config", "marker"), "wb") as handle:
    handle.write(payload)
two_files = os.path.join(root, "two-files", "config")
os.makedirs(two_files)
for name in ("marker", "second"):
    with open(os.path.join(two_files, name), "wb") as handle:
        handle.write(payload)
with open(os.path.join(root, "sizes"), "w") as handle:
    handle.write("%s %s %s\n" % (compressed_size, expanded_size, len(payload)))
PY
IFS=' ' read -r ARCHIVE_BYTES TAR_BYTES PAYLOAD_BYTES <"$TEST_DIR/fixtures/sizes"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$OUTPUT" ] || cat "$OUTPUT" >&2
  [ ! -f "$TRACE" ] || cat "$TRACE" >&2
  exit 1
}

function passed() {
  PASSED=$((PASSED + 1))
  printf '[tests] PASS: %s\n' "$*"
}

function record_action() { printf '%s\n' "$*" >>"$TRACE"; }
function confirm_prompt() { record_action confirm; [ "$CONFIRM" = true ]; }
# Stop at the first live-state boundary. An admitted input must reach this
# boundary; a rejected input must not. No real config mutation is necessary.
function begin_transaction() { record_action transaction; return 1; }
function fix_permissions() { record_action unexpected-permissions; return 1; }
function update_nginx_config() { record_action unexpected-render; return 1; }
function ensure_no_nginx_container_conflict() { record_action unexpected-runtime; return 1; }

workspace_definition="$(declare -f _backup_make_private_restore_dir)"
eval "${workspace_definition/_backup_make_private_restore_dir/_original_intake_make_workspace}"
function _backup_make_private_restore_dir() {
  record_action workspace
  _original_intake_make_workspace "$@"
}
checksum_definition="$(declare -f _verify_backup_archive_checksum_if_present)"
eval "${checksum_definition/_verify_backup_archive_checksum_if_present/_original_intake_verify_checksum}"
function _verify_backup_archive_checksum_if_present() {
  record_action checksum
  _original_intake_verify_checksum "$@"
}

function reset_attempt() {
  unset RESTORE_MAX_ARCHIVE_BYTES RESTORE_MAX_EXPANDED_BYTES RESTORE_MAX_ENTRIES
  CONFIRM=true
  : >"$TRACE"
  : >"$OUTPUT"
}

function state_fingerprint() {
  "$PYTHON" - "$CONFIG_DIR" "$LOG_DIR" <<'PY'
import hashlib
import os
import stat
import sys
for root in sys.argv[1:]:
    paths = [root]
    for current, dirs, files in os.walk(root):
        paths.extend(os.path.join(current, name) for name in dirs + files)
    for path in sorted(paths):
        metadata = os.lstat(path)
        digest = ""
        if stat.S_ISREG(metadata.st_mode):
            with open(path, "rb") as handle:
                digest = hashlib.sha256(handle.read()).hexdigest()
        print(repr((path, metadata.st_dev, metadata.st_ino, metadata.st_mode,
                    metadata.st_uid, metadata.st_gid, metadata.st_mtime_ns, digest)))
PY
}
state_fingerprint >"$TEST_DIR/state-before"

function assert_unchanged_and_cleaned() {
  local entry=""
  state_fingerprint >"$TEST_DIR/state-after"
  cmp -s "$TEST_DIR/state-before" "$TEST_DIR/state-after" || fail_test 'intake changed live state'
  for entry in "$TMP_DIR"/restore_*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || fail_test 'intake left a restore workspace'
  done
  if grep -q '^unexpected-' "$TRACE"; then fail_test 'intake reached a live mutation'; fi
}

function expect_rejected() {
  local label="$1" source="$2" diagnostic="${3:-}"
  if restore_backup "$source" >"$OUTPUT" 2>&1; then fail_test "$label was accepted"; fi
  if grep -qx transaction "$TRACE"; then fail_test "$label reached the transaction"; fi
  assert_unchanged_and_cleaned
  if [ -n "$diagnostic" ] && ! grep -Eqi "$diagnostic" "$OUTPUT"; then
    fail_test "$label lacked a useful diagnostic"
  fi
  passed "$label"
}

function expect_admitted() {
  local label="$1" source="$2"
  if restore_backup "$source" >"$OUTPUT" 2>&1; then
    fail_test "$label ignored the intentionally failed transaction start"
  fi
  grep -qx transaction "$TRACE" || fail_test "$label was rejected before the transaction"
  assert_unchanged_and_cleaned
  passed "$label"
}

case "$SELECTION" in all | cancel)
  for input in "$TEST_DIR/fixtures/safe.tar.gz" "$TEST_DIR/fixtures/directory"; do
    reset_attempt
    CONFIRM=false
    restore_backup "$input" >"$OUTPUT" 2>&1 || fail_test 'ordinary cancellation failed'
    [ "$(cat "$TRACE")" = confirm ] || fail_test 'cancellation copied, checksummed or expanded the source before confirmation'
    assert_unchanged_and_cleaned
    passed "cancel before copying $(basename "$input")"
  done
  ;;
esac

case "$SELECTION" in all | limits)
  reset_attempt
  RESTORE_MAX_ARCHIVE_BYTES="$ARCHIVE_BYTES"
  RESTORE_MAX_EXPANDED_BYTES="$TAR_BYTES"
  RESTORE_MAX_ENTRIES=3
  expect_admitted 'archive exactly at all three budgets' "$TEST_DIR/fixtures/safe.tar.gz"

  reset_attempt
  RESTORE_MAX_ARCHIVE_BYTES=$((ARCHIVE_BYTES - 1))
  expect_rejected 'compressed archive one byte over budget' "$TEST_DIR/fixtures/safe.tar.gz" 'archive|compressed|limit|budget'

  reset_attempt
  RESTORE_MAX_EXPANDED_BYTES=$((TAR_BYTES - 1))
  expect_rejected 'expanded tar one byte over budget' "$TEST_DIR/fixtures/safe.tar.gz" 'expand|limit|budget'

  reset_attempt
  RESTORE_MAX_ENTRIES=2
  expect_rejected 'archive directory members count toward budget' "$TEST_DIR/fixtures/safe.tar.gz" 'entr|member|limit|budget'

  reset_attempt
  RESTORE_MAX_ENTRIES=7
  expect_rejected 'zero-byte members count toward budget' "$TEST_DIR/fixtures/many.tar.gz" 'entr|member|limit|budget'
  RESTORE_MAX_ENTRIES=8
  : >"$TRACE"
  expect_admitted 'explicitly raised entry budget' "$TEST_DIR/fixtures/many.tar.gz"

  reset_attempt
  RESTORE_MAX_ENTRIES=3
  expect_rejected 'implicit parent directories count toward budget' "$TEST_DIR/fixtures/implicit-parents.tar.gz" 'entr|member|path|limit|budget'
  RESTORE_MAX_ENTRIES=4
  : >"$TRACE"
  expect_admitted 'implicit parents at the exact entry budget' "$TEST_DIR/fixtures/implicit-parents.tar.gz"

  reset_attempt
  RESTORE_MAX_EXPANDED_BYTES="$TAR_BYTES"
  expect_rejected 'concatenated gzip trailer counts toward expansion' "$TEST_DIR/fixtures/trailing.tar.gz" 'expand|limit|budget'

  reset_attempt
  RESTORE_MAX_EXPANDED_BYTES="$TAR_BYTES"
  expect_rejected 'PAX metadata counts toward expansion' "$TEST_DIR/fixtures/metadata.tar.gz" 'expand|limit|budget'

  reset_attempt
  RESTORE_MAX_EXPANDED_BYTES=$((TAR_BYTES + 65536))
  expect_admitted 'large raw tar padding inside the explicit budget' "$TEST_DIR/fixtures/padded.tar.gz"

  reset_attempt
  RESTORE_MAX_ENTRIES=3
  expect_rejected 'members after tar terminators count toward the budget' "$TEST_DIR/fixtures/concatenated.tar.gz" 'entr|member|limit|budget'
  RESTORE_MAX_ENTRIES=4
  : >"$TRACE"
  expect_admitted 'concatenated raw tar members inside explicit budgets' "$TEST_DIR/fixtures/concatenated.tar.gz"
  reset_attempt
  expect_rejected 'duplicate paths after tar terminators are rejected' "$TEST_DIR/fixtures/concatenated-duplicate.tar.gz" 'duplicate|conflict'

  reset_attempt
  RESTORE_MAX_EXPANDED_BYTES=32768
  expect_rejected 'sparse logical size exceeds budget' "$TEST_DIR/fixtures/sparse.tar.gz" 'sparse|size|expand|limit|budget'
  RESTORE_MAX_EXPANDED_BYTES=1048576
  : >"$TRACE"
  expect_admitted 'explicitly raised sparse logical-size budget' "$TEST_DIR/fixtures/sparse.tar.gz"
  : >"$TRACE"
  expect_rejected 'sparse logical sizes are summed across files' "$TEST_DIR/fixtures/sparse-sum.tar.gz" 'size|expand|limit|budget'

  reset_attempt
  expect_admitted 'PAX long filename remains supported' "$TEST_DIR/fixtures/long-name.tar.gz"
  for name in gnu-header v7-header; do
    reset_attempt
    expect_admitted "$name remains a supported raw tar format" "$TEST_DIR/fixtures/$name.tar.gz"
  done

  reset_attempt
  RESTORE_MAX_ARCHIVE_BYTES=1
  RESTORE_MAX_EXPANDED_BYTES="$PAYLOAD_BYTES"
  RESTORE_MAX_ENTRIES=3
  expect_admitted 'directory at payload and entry budgets ignores compressed-only cap' "$TEST_DIR/fixtures/directory"
  RESTORE_MAX_EXPANDED_BYTES=$((PAYLOAD_BYTES - 1))
  : >"$TRACE"
  expect_rejected 'directory payload one byte over budget' "$TEST_DIR/fixtures/directory" 'size|expand|limit|budget'
  RESTORE_MAX_EXPANDED_BYTES="$PAYLOAD_BYTES"
  RESTORE_MAX_ENTRIES=2
  : >"$TRACE"
  expect_rejected 'directory root counts toward entry budget' "$TEST_DIR/fixtures/directory" 'entr|member|limit|budget'
  reset_attempt
  RESTORE_MAX_EXPANDED_BYTES=$((PAYLOAD_BYTES * 2 - 1))
  expect_rejected 'directory payload sizes are summed across files' "$TEST_DIR/fixtures/two-files" 'size|expand|limit|budget'
  RESTORE_MAX_EXPANDED_BYTES=$((PAYLOAD_BYTES * 2))
  : >"$TRACE"
  expect_admitted 'directory total payload at its exact budget' "$TEST_DIR/fixtures/two-files"
  ;;
esac

case "$SELECTION" in all | invalid)
  for variable in RESTORE_MAX_ARCHIVE_BYTES RESTORE_MAX_EXPANDED_BYTES RESTORE_MAX_ENTRIES; do
    for value in '' 0 -1 +1 ' 1' '1 ' 1.5 1k 9007199254740991 999999999999999999999999; do
      reset_attempt
      printf -v "$variable" '%s' "$value"
      expect_rejected "invalid $variable value '$value'" "$TEST_DIR/fixtures/safe.tar.gz" "$variable|limit|budget"
      [ ! -s "$TRACE" ] || fail_test 'invalid limit performed work or requested confirmation'
    done
  done
  reset_attempt
  RESTORE_MAX_ARCHIVE_BYTES=0001048576
  RESTORE_MAX_EXPANDED_BYTES=0001048576
  RESTORE_MAX_ENTRIES=0003
  expect_admitted 'leading-zero limits are decimal values' "$TEST_DIR/fixtures/safe.tar.gz"
  ;;
esac

case "$SELECTION" in all | failure)
  for name in corrupt truncated; do
    reset_attempt
    expect_rejected "$name gzip input" "$TEST_DIR/fixtures/$name.tar.gz" 'gzip|archive|expand|decompress|invalid|fail'
  done
  reset_attempt
  cp "$TEST_DIR/fixtures/safe.tar.gz" "$TEST_DIR/fixtures/checksum.tar.gz"
  printf '%064d  checksum.tar.gz\n' 0 >"$TEST_DIR/fixtures/checksum.tar.gz.sha256"
  expect_rejected 'checksum mismatch' "$TEST_DIR/fixtures/checksum.tar.gz" 'checksum'

  reset_attempt
  mkdir "$TEST_DIR/fixtures/unsafe"
  ln -s "$CONFIG_DIR" "$TEST_DIR/fixtures/unsafe/config"
  expect_rejected 'directory symlink rejected before live state' "$TEST_DIR/fixtures/unsafe" 'symlink|unsafe|physical|link'

  for name in empty multiple-roots; do
    reset_attempt
    expect_rejected "$name archive has no unique backup root" "$TEST_DIR/fixtures/$name.tar.gz"
  done

  reset_attempt
  ln -s "$TEST_DIR/fixtures/safe.tar.gz" "$TEST_DIR/fixtures/archive-alias.tar.gz"
  digest="$(_sha256_digest_file "$TEST_DIR/fixtures/safe.tar.gz")"
  printf '%s  archive-alias.tar.gz\n' "$digest" >"$TEST_DIR/fixtures/digest"
  ln -s "$TEST_DIR/fixtures/digest" "$TEST_DIR/fixtures/archive-alias.tar.gz.sha256"
  expect_admitted 'operator archive and checksum aliases use bounded snapshots' "$TEST_DIR/fixtures/archive-alias.tar.gz"
  ;;
esac

case "$SELECTION" in all | nested)
  function tar() {
    printf '%s\n' "$*" >>"$TEST_DIR/nested-tar-calls"
    command tar "$@"
  }
  for name in double-gzip gzip-zip bad-header; do
    reset_attempt
    : >"$TEST_DIR/nested-tar-calls"
    RESTORE_MAX_EXPANDED_BYTES="$TAR_BYTES"
    expect_rejected "$name cannot bypass the raw tar expansion budget" "$TEST_DIR/fixtures/$name.tar.gz"
    [ ! -s "$TEST_DIR/nested-tar-calls" ] || fail_test "$name reached tar's automatic format detection"
  done
  unset -f tar
  ;;
esac

case "$SELECTION" in all | cleanup)
  cleanup_definition="$(declare -f _backup_remove_private_restore_dir)"
  function _backup_remove_private_restore_dir() { return 1; }
  reset_attempt
  RESTORE_MAX_ARCHIVE_BYTES=1
  if restore_backup "$TEST_DIR/fixtures/safe.tar.gz" >"$OUTPUT" 2>&1; then
    fail_test 'intake cleanup failure became a successful restore'
  fi
  if grep -qx transaction "$TRACE"; then fail_test 'cleanup failure reached the transaction'; fi
  retained_count=0
  for retained in "$TMP_DIR"/restore_*; do
    [ -d "$retained" ] || continue
    retained_count=$((retained_count + 1))
    grep -Fq "$retained" "$OUTPUT" || fail_test 'cleanup failure did not identify its retained workspace'
  done
  [ "$retained_count" -eq 1 ] || fail_test 'cleanup failure did not retain exactly its own workspace'
  grep -Eqi 'failed.*(remove|cleanup)|retained workspace' "$OUTPUT" || fail_test 'cleanup failure lacked a clear diagnostic'
  unset -f _backup_remove_private_restore_dir
  eval "$cleanup_definition"
  for retained in "$TMP_DIR"/restore_*; do
    [ ! -e "$retained" ] || _backup_remove_private_restore_dir "$retained" || fail_test 'could not remove owned recovery fixture'
  done
  assert_unchanged_and_cleaned
  passed 'cleanup failure reports retained private staging without changing live state'
  ;;
esac

case "$SELECTION" in all | fd)
  fd_saved_path="$PATH"
  mkdir "$TEST_DIR/bsd-stat-bin"
  export RESTORE_STAT_TRACE="$TEST_DIR/bsd-stat-trace"
  export RESTORE_STAT_UNSUPPORTED="$TEST_DIR/bsd-stat-unsupported"
  export RESTORE_STAT_PYTHON="$PYTHON"
  export RESTORE_STAT_HELPER="$ROOT_DIR/tests/helpers/restore_intake_bsd_stat.py"
  cat >"$TEST_DIR/bsd-stat-bin/stat" <<'SHIM'
#!/usr/bin/env bash
# Preserve real stdin for BSD fstat, including directories, without asking
# Python's standard-stream initialization to accept a directory on fd 0.
export RESTORE_STAT_STDIN_FD=9
exec "$RESTORE_STAT_PYTHON" "$RESTORE_STAT_HELPER" "$@" 9<&0 </dev/null
SHIM
  chmod 700 "$TEST_DIR/bsd-stat-bin/stat"
  PATH="$TEST_DIR/bsd-stat-bin:$PATH"

  # Prove the fixture models fdescfs rather than silently following Linux's
  # /proc descriptor links. Only the device differs; the inode is retained.
  path_identity="$(_restore_intake_stat "$TEST_DIR/fixtures/safe.tar.gz")" || fail_test 'BSD stat fixture could not inspect the source'
  {
    fdesc_identity="$(_restore_intake_stat /dev/fd/3)" || fail_test 'BSD stat fixture could not inspect fdescfs'
  } 3<"$TEST_DIR/fixtures/safe.tar.gz"
  [ "$path_identity" != "$fdesc_identity" ] || fail_test 'BSD stat fixture did not model the fdescfs device difference'
  [ "${path_identity#*:}" = "${fdesc_identity#*:}" ] || fail_test 'BSD stat fixture changed more than the fdescfs device'
  for stdin_path in /dev/stdin /dev/fd/0; do
    stdin_identity="$(_restore_intake_stat "$stdin_path" <"$TEST_DIR/fixtures/safe.tar.gz")" ||
      fail_test 'BSD stat fixture could not inspect a stdin alias'
    [ "$stdin_identity" = "$fdesc_identity" ] || fail_test 'BSD stat fixture lost the original stdin identity'
  done
  passed 'BSD stat fixture preserves opened-file metadata through descriptor and stdin aliases'
  if _restore_intake_stat /dev/fd/3 3<&- >"$OUTPUT" 2>"$TEST_DIR/fd-error"; then
    fail_test 'BSD stat fixture admitted a closed descriptor'
  fi
  [ ! -s "$OUTPUT" ] || fail_test 'closed descriptor published a file identity'
  for invalid_descriptor in /dev/fd/not-a-number /dev/fd/+3 '/dev/fd/ 3' /dev/fd/999999999999999999999999; do
    if _restore_intake_stat "$invalid_descriptor" 3<"$TEST_DIR/fixtures/safe.tar.gz" >"$OUTPUT" 2>"$TEST_DIR/fd-error"; then
      fail_test 'BSD stat fixture admitted an invalid descriptor'
    fi
    [ ! -s "$OUTPUT" ] || fail_test 'invalid descriptor published a file identity'
  done
  passed 'BSD stat fixture rejects closed and malformed descriptors'
  : >"$RESTORE_STAT_TRACE"

  reset_attempt
  expect_admitted 'BSD stdin fstat admits an unchanged archive despite fdescfs metadata' "$TEST_DIR/fixtures/safe.tar.gz"
  reset_attempt
  expect_admitted 'BSD stdin fstat admits an unchanged directory' "$TEST_DIR/fixtures/directory"
  reset_attempt
  ln -s "$TEST_DIR/fixtures/safe.tar.gz" "$TEST_DIR/fixtures/fd-alias.tar.gz"
  digest="$(_sha256_digest_file "$TEST_DIR/fixtures/safe.tar.gz")"
  printf '%s  fd-alias.tar.gz\n' "$digest" >"$TEST_DIR/fixtures/fd-digest"
  ln -s "$TEST_DIR/fixtures/fd-digest" "$TEST_DIR/fixtures/fd-alias.tar.gz.sha256"
  expect_admitted 'BSD stdin fstat preserves archive and checksum aliases' "$TEST_DIR/fixtures/fd-alias.tar.gz"
  grep -q '^stdin' "$RESTORE_STAT_TRACE" || fail_test 'BSD descriptor checks did not inspect stdin'
  grep -Fxq "$(printf 'stdin\t%s\t' '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc')" "$RESTORE_STAT_TRACE" ||
    fail_test 'BSD capability checks did not inspect full stdin metadata'
  if grep -q '^fdescfs' "$RESTORE_STAT_TRACE"; then fail_test 'restore compared descriptor-path metadata with source metadata'; fi

  {
    expected_identity="$(_restore_intake_stat "$TEST_DIR/fixtures/directory/config/marker")"
    opened_identity="$(_restore_intake_fstat_regular <&3)" || fail_test 'BSD descriptor inspection rejected a regular file'
    [ "$expected_identity" = "$opened_identity" ] || fail_test 'BSD descriptor inspection did not return the opened file identity'
    IFS= read -r -n 1 first_byte <&3 || fail_test 'BSD descriptor inspection consumed the file'
    [ "$first_byte" = r ] || fail_test 'BSD descriptor inspection changed the open file offset'
  } 3<"$TEST_DIR/fixtures/directory/config/marker"
  passed 'BSD descriptor inspection preserves identity and file offset'
  for nonregular in "$TEST_DIR/fixtures/directory" /dev/null; do
    if _restore_intake_fstat_regular <"$nonregular" >"$OUTPUT" 2>"$TEST_DIR/fd-error"; then
      fail_test 'BSD descriptor inspection admitted a nonregular object'
    fi
    [ ! -s "$OUTPUT" ] || fail_test 'nonregular descriptor published a file identity'
    passed "BSD descriptor inspection rejects $(basename "$nonregular")"
  done
  if printf 'pipe data\n' | _restore_intake_fstat_regular >"$OUTPUT" 2>"$TEST_DIR/fd-error"; then
    fail_test 'BSD descriptor inspection admitted a pipe'
  fi
  [ ! -s "$OUTPUT" ] || fail_test 'pipe descriptor published a file identity'
  passed 'BSD descriptor inspection rejects pipes'
  if _restore_intake_fstat_regular <&- >"$OUTPUT" 2>"$TEST_DIR/fd-error"; then
    fail_test 'BSD descriptor inspection admitted closed stdin'
  fi
  [ ! -s "$OUTPUT" ] || fail_test 'closed descriptor published a file identity'
  passed 'BSD descriptor inspection rejects closed stdin'

  fd_definition="$(declare -f _restore_intake_fstat_regular)"
  eval "${fd_definition/_restore_intake_fstat_regular/_fd_original_fstat_regular}"
  function _restore_intake_fstat_regular() {
    local record=""
    record="$(_fd_original_fstat_regular)" || return 1
    if [ ! -e "$TEST_DIR/fd-swapped" ]; then
      "$PYTHON" -c '
import os, sys
path, marker = sys.argv[1:]
opened, current = os.fstat(0), os.stat(path)
if (opened.st_dev, opened.st_ino) == (current.st_dev, current.st_ino):
    with open(path, "rb") as source, open(path + ".replacement", "wb") as target:
        target.write(source.read())
    os.utime(path + ".replacement", ns=(current.st_atime_ns, current.st_mtime_ns))
    os.replace(path + ".replacement", path)
    with open(marker, "w") as handle:
        handle.write("replaced same-size path after open\n")
' "$FD_SWAP_SOURCE" "$TEST_DIR/fd-swapped" || return 1
    fi
    printf '%s\n' "$record"
  }
  cp "$TEST_DIR/fixtures/safe.tar.gz" "$TEST_DIR/fixtures/fd-swap.tar.gz"
  FD_SWAP_SOURCE="$TEST_DIR/fixtures/fd-swap.tar.gz"
  reset_attempt
  expect_rejected 'BSD fstat rejects a same-size source replacement after opening' "$FD_SWAP_SOURCE" 'changed while being copied'
  [ -f "$TEST_DIR/fd-swapped" ] || fail_test 'descriptor race fixture never replaced the opened source'
  unset -f _restore_intake_fstat_regular _fd_original_fstat_regular
  eval "$fd_definition"
  [ ! -s "$RESTORE_STAT_UNSUPPORTED" ] || fail_test 'BSD stat fixture encountered an unsupported invocation'
  PATH="$fd_saved_path"
  unset RESTORE_STAT_TRACE RESTORE_STAT_UNSUPPORTED RESTORE_STAT_PYTHON RESTORE_STAT_HELPER
  ;;
esac

case "$SELECTION" in all | growth)
  # Mutate the real opened input after recording its identity. This models
  # growth between the metadata check and the copy without a timing race.
  stat_definition="$(declare -f _restore_intake_fstat_regular)"
  eval "${stat_definition/_restore_intake_fstat_regular/_original_intake_fstat_regular}"
  function _restore_intake_fstat_regular() {
    local record=""
    record="$(_original_intake_fstat_regular)" || return 1
    if [ ! -e "$TEST_DIR/growth-injected" ] && "$PYTHON" -c '
import os, sys
opened, source = os.fstat(0), os.stat(sys.argv[1])
sys.exit((opened.st_dev, opened.st_ino) != (source.st_dev, source.st_ino))
' "$GROW_SOURCE"; then
      printf 'appended after the descriptor was checked\n' >>"$GROW_SOURCE"
      : >"$TEST_DIR/growth-injected"
    fi
    printf '%s\n' "$record"
  }
  for kind in archive directory; do
    reset_attempt
    rm -f "$TEST_DIR/growth-injected"
    if [ "$kind" = archive ]; then
      cp "$TEST_DIR/fixtures/safe.tar.gz" "$TEST_DIR/fixtures/growing.tar.gz"
      GROW_SOURCE="$TEST_DIR/fixtures/growing.tar.gz"
      GROW_INPUT="$GROW_SOURCE"
      RESTORE_MAX_ARCHIVE_BYTES="$ARCHIVE_BYTES"
    else
      cp -R "$TEST_DIR/fixtures/directory" "$TEST_DIR/fixtures/growing-directory"
      GROW_SOURCE="$TEST_DIR/fixtures/growing-directory/config/marker"
      GROW_INPUT="$TEST_DIR/fixtures/growing-directory"
      RESTORE_MAX_EXPANDED_BYTES="$PAYLOAD_BYTES"
    fi
    expect_rejected "$kind growth is stopped during the bounded copy" "$GROW_INPUT" 'exceeds.*limit'
    [ -f "$TEST_DIR/growth-injected" ] || fail_test 'growth regression did not reach the opened descriptor'
  done
  unset -f _restore_intake_fstat_regular _original_intake_fstat_regular
  eval "$stat_definition"

  # A producer may emit apparently complete output before failing. Its status
  # must still reject the restore and remove every partial staging artifact.
  function gzip() {
    command gzip "$@" || return $?
    return 73
  }
  reset_attempt
  expect_rejected 'gzip failure after complete output is observed' "$TEST_DIR/fixtures/safe.tar.gz" 'expand|fail'
  unset -f gzip

  function tar() {
    command tar "$@" || return $?
    if [ "${1:-}" = -tf ]; then return 74; fi
  }
  reset_attempt
  expect_rejected 'tar listing failure after complete output is observed' "$TEST_DIR/fixtures/safe.tar.gz"
  unset -f tar

  function head() {
    if [ "${1:-}" = -c ]; then
      command head -c 8 || return $?
      return 75
    fi
    command head "$@"
  }
  reset_attempt
  expect_rejected 'partial copy I/O failure cleans the private workspace' "$TEST_DIR/fixtures/safe.tar.gz" 'read|fail'
  unset -f head
  ;;
esac

case "$SELECTION" in all | isolation)
  bounded_definition="$(declare -f _restore_intake_bounded_stream)"
  eval "${bounded_definition/_restore_intake_bounded_stream/_original_intake_bounded_stream}"
  function _restore_intake_bounded_stream() {
    trap -p ERR >>"$TEST_DIR/worker-err-traps"
    _original_intake_bounded_stream "$@"
  }
  : >"$TEST_DIR/parent-trap-events"
  : >"$TEST_DIR/worker-err-traps"
  (
    trap 'printf "caller-exit\n" >>"$TEST_DIR/parent-trap-events"' EXIT
    trap 'printf "caller-err\n" >>"$TEST_DIR/parent-trap-events"' ERR
    parent_traps="$(trap -p ERR EXIT)"
    parent_options="$-"
    parent_umask="$(umask)"
    reset_attempt
    RESTORE_MAX_ARCHIVE_BYTES=1
    expect_rejected 'bounded failure isolates caller traps and shell state' "$TEST_DIR/fixtures/safe.tar.gz" 'limit'
    [ "$(trap -p ERR EXIT)" = "$parent_traps" ] || fail_test 'intake replaced caller traps'
    [ "$-" = "$parent_options" ] || fail_test 'intake changed caller shell options'
    [ "$(umask)" = "$parent_umask" ] || fail_test 'intake changed caller umask'
    [ ! -s "$TEST_DIR/worker-err-traps" ] || fail_test 'private intake worker retained caller ERR trap'
    [ ! -s "$TEST_DIR/parent-trap-events" ] || fail_test 'private intake worker invoked caller traps'
  ) || fail_test 'caller trap isolation checks failed'
  [ "$(cat "$TEST_DIR/parent-trap-events")" = caller-exit ] || fail_test 'caller EXIT trap did not remain intact'
  unset -f _restore_intake_bounded_stream _original_intake_bounded_stream
  eval "$bounded_definition"
  PASSED=$((PASSED + 1))
  ;;
esac

case "$SELECTION" in all | rollback)
  reset_attempt
  RESTORE_MAX_ARCHIVE_BYTES=invalid
  RESTORE_MAX_EXPANDED_BYTES=0
  RESTORE_MAX_ENTRIES=''
  restore_backup_archive "$TEST_DIR/fixtures/rollback.tar.gz" "$CONFIG_DIR" >"$OUTPUT" 2>&1 || fail_test 'public restore limits prevented internal rollback'
  grep -qx 'restored configuration' "$CONFIG_DIR/marker" || fail_test 'internal rollback did not replay its configuration'
  passed 'internal rollback is independent of public restore budgets'
  ;;
esac

[ "$PASSED" -gt 0 ] || fail_test "unknown selected intake test group: $SELECTION"
printf '[tests] restore_backup_intake_limits.sh: PASS (%s cases)\n' "$PASSED"
