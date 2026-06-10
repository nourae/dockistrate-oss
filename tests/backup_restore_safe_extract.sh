#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/backups/common.sh
source "$ROOT_DIR/lib/backups/common.sh"

if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "[Error] python3 (or python) is required for tar generation" >&2
  exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() {
  chmod -R u+rwx "$tmp_root" 2>/dev/null || true
  rm -rf "$tmp_root"
}
trap cleanup EXIT

safe_archive="$tmp_root/safe.tar.gz"
empty_archive="$tmp_root/empty.tar.gz"
dot_archive="$tmp_root/dot.tar.gz"
pax_archive="$tmp_root/pax.tar.gz"
bad_abs_archive="$tmp_root/bad_abs.tar.gz"
bad_dotdot_archive="$tmp_root/bad_dotdot.tar.gz"
bad_dot_mixed_archive="$tmp_root/bad_dot_mixed.tar.gz"
bad_symlink_archive="$tmp_root/bad_symlink.tar.gz"
bad_hardlink_archive="$tmp_root/bad_hardlink.tar.gz"
bad_fifo_archive="$tmp_root/bad_fifo.tar.gz"
bad_block_archive="$tmp_root/bad_block.tar.gz"
bad_char_archive="$tmp_root/bad_char.tar.gz"

"$PYTHON" - "$safe_archive" "$empty_archive" "$dot_archive" "$pax_archive" \
  "$bad_abs_archive" "$bad_dotdot_archive" "$bad_dot_mixed_archive" \
  "$bad_symlink_archive" "$bad_hardlink_archive" \
  "$bad_fifo_archive" "$bad_block_archive" "$bad_char_archive" <<'PY'
import io
import sys
import tarfile

def add_file(tar, name, data=b"hi"):
    ti = tarfile.TarInfo(name)
    ti.mode = 0o644
    ti.size = len(data)
    tar.addfile(ti, io.BytesIO(data))

def add_dir(tar, name):
    ti = tarfile.TarInfo(name)
    ti.type = tarfile.DIRTYPE
    ti.mode = 0o755
    tar.addfile(ti)

def add_special(tar, name, type_, linkname="", devmajor=0, devminor=0):
    ti = tarfile.TarInfo(name)
    ti.type = type_
    ti.mode = 0o644
    ti.linkname = linkname
    ti.devmajor = devmajor
    ti.devminor = devminor
    tar.addfile(ti)

safe, empty, dot, pax, bad_abs, bad_dotdot, bad_dot_mixed, bad_symlink, bad_hardlink, bad_fifo, bad_block, bad_char = sys.argv[1:]
with tarfile.open(safe, "w:gz") as tar:
    add_dir(tar, "backup_dir/")
    add_dir(tar, "backup_dir/config/")
    add_dir(tar, "backup_dir/config/empty/")
    add_file(tar, "backup_dir/config/file.txt")
with tarfile.open(empty, "w:gz"):
    pass
with tarfile.open(dot, "w:gz") as tar:
    add_dir(tar, ".")
with tarfile.open(pax, "w:gz", format=tarfile.PAX_FORMAT) as tar:
    tar.pax_headers = {"comment": "global pax metadata"}
    long_dir = "backup_dir/config/" + ("longsegment" * 12)
    add_dir(tar, "backup_dir/")
    add_dir(tar, "backup_dir/config/")
    add_dir(tar, long_dir + "/")
    add_file(tar, long_dir + "/file.txt")
with tarfile.open(bad_abs, "w:gz") as tar:
    add_file(tar, "/abs/evil.txt")
with tarfile.open(bad_dotdot, "w:gz") as tar:
    add_file(tar, "../evil.txt")
with tarfile.open(bad_dot_mixed, "w:gz") as tar:
    add_dir(tar, ".")
    add_file(tar, "payload.txt")
with tarfile.open(bad_symlink, "w:gz") as tar:
    add_special(tar, "backup_dir/config/link", tarfile.SYMTYPE, linkname="file.txt")
with tarfile.open(bad_hardlink, "w:gz") as tar:
    add_file(tar, "backup_dir/config/file.txt")
    add_special(tar, "backup_dir/config/hardlink", tarfile.LNKTYPE, linkname="backup_dir/config/file.txt")
with tarfile.open(bad_fifo, "w:gz") as tar:
    add_special(tar, "backup_dir/config/file.fifo", tarfile.FIFOTYPE)
with tarfile.open(bad_block, "w:gz") as tar:
    add_special(tar, "backup_dir/config/device.block", tarfile.BLKTYPE, devmajor=1, devminor=7)
with tarfile.open(bad_char, "w:gz") as tar:
    add_special(tar, "backup_dir/config/device.char", tarfile.CHRTYPE, devmajor=1, devminor=3)
PY

expect_validate_success() {
  local archive="$1" label="$2"
  if ! _validate_tar_entries_safe "$archive"; then
    echo "[Error] Expected ${label} archive to pass validation" >&2
    exit 1
  fi
}

expect_validate_failure() {
  local archive="$1" label="$2"
  if _validate_tar_entries_safe "$archive"; then
    echo "[Error] Expected ${label} archive to fail validation" >&2
    exit 1
  fi
}

expect_extract_failure() {
  local archive="$1" label="$2"
  if _safe_extract_tar "$archive" "$tmp_root/${label}_dest"; then
    echo "[Error] Expected unsafe ${label} archive to fail extraction" >&2
    exit 1
  fi
}

expect_validate_success "$safe_archive" "safe"
expect_validate_success "$empty_archive" "empty no-op"
expect_validate_success "$dot_archive" "dot no-op"
expect_validate_success "$pax_archive" "PAX metadata"
expect_validate_failure "$bad_abs_archive" "absolute-path"
expect_validate_failure "$bad_dotdot_archive" "dotdot"
expect_validate_failure "$bad_dot_mixed_archive" "mixed dot"
expect_validate_failure "$bad_symlink_archive" "symlink"
expect_validate_failure "$bad_hardlink_archive" "hardlink"
expect_validate_failure "$bad_fifo_archive" "FIFO"
expect_validate_failure "$bad_block_archive" "block-device"
expect_validate_failure "$bad_char_archive" "character-device"

dest="$tmp_root/dest"
if ! _safe_extract_tar "$safe_archive" "$dest"; then
  echo "[Error] Expected safe archive to extract" >&2
  exit 1
fi
if [ ! -f "$dest/backup_dir/config/file.txt" ]; then
  echo "[Error] Extracted file missing" >&2
  exit 1
fi
if [ ! -d "$dest/backup_dir/config/empty" ]; then
  echo "[Error] Extracted directory missing" >&2
  exit 1
fi
empty_dest="$tmp_root/empty_dest"
if ! _safe_extract_tar "$empty_archive" "$empty_dest"; then
  echo "[Error] Expected empty no-op archive to extract" >&2
  exit 1
fi
if find "$empty_dest" -mindepth 1 -print -quit | grep -q .; then
  echo "[Error] Empty no-op archive should not extract filesystem entries" >&2
  exit 1
fi
dot_dest="$tmp_root/dot_dest"
if ! _safe_extract_tar "$dot_archive" "$dot_dest"; then
  echo "[Error] Expected dot no-op archive to extract" >&2
  exit 1
fi
if find "$dot_dest" -mindepth 1 -print -quit | grep -q .; then
  echo "[Error] Dot no-op archive should not extract filesystem entries" >&2
  exit 1
fi
pax_dest="$tmp_root/pax_dest"
if ! _safe_extract_tar "$pax_archive" "$pax_dest"; then
  echo "[Error] Expected PAX metadata archive to extract" >&2
  exit 1
fi
pax_long_component="$(printf 'longsegment%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)"
if [ ! -f "$pax_dest/backup_dir/config/${pax_long_component}/file.txt" ]; then
  echo "[Error] Extracted PAX long-path file missing" >&2
  exit 1
fi

expect_extract_failure "$bad_abs_archive" "bad_abs"
expect_extract_failure "$bad_dotdot_archive" "bad_dotdot"
expect_extract_failure "$bad_dot_mixed_archive" "bad_dot_mixed"
expect_extract_failure "$bad_symlink_archive" "bad_symlink"
expect_extract_failure "$bad_hardlink_archive" "bad_hardlink"
expect_extract_failure "$bad_fifo_archive" "bad_fifo"
expect_extract_failure "$bad_block_archive" "bad_block"
expect_extract_failure "$bad_char_archive" "bad_char"

echo "Safe archive validation checks passed."
