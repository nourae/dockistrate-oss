#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-state-append.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/common.sh
source "$ROOT_DIR/lib/utils/common.sh"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck source=../lib/utils/state_csv.sh
source "$ROOT_DIR/lib/utils/state_csv.sh"

function assert_file_equals() {
  local expected="$1" file="$2"
  local actual
  actual="$(cat "$file")"
  if [ "$actual" != "$expected" ]; then
    printf '[Error] Expected file contents:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
}

state_file="$TMP_DIR/state.csv"
printf '%s\n' "a,b,c" "1,2,3" >"$state_file"

state_csv_append_row_line "$state_file" "a,b,c" 3 "4,5,6"
assert_file_equals $'a,b,c\n1,2,3\n4,5,6' "$state_file"

before="$(cat "$state_file")"
if state_csv_append_row_line "$state_file" "a,b,c" 3 "7,8" 2>"$TMP_DIR/narrow-row.err"; then
  echo "[Error] state_csv_append_row_line accepted a narrow row." >&2
  exit 1
fi
assert_file_equals "$before" "$state_file"

bad_existing="$TMP_DIR/bad-existing.csv"
printf '%s\n' "a,b,c" "1,2" >"$bad_existing"
before="$(cat "$bad_existing")"
if state_csv_append_row_line "$bad_existing" "a,b,c" 3 "4,5,6" 2>"$TMP_DIR/bad-existing.err"; then
  echo "[Error] state_csv_append_row_line accepted an existing narrow row." >&2
  exit 1
fi
assert_file_equals "$before" "$bad_existing"

write_fail="$TMP_DIR/write-fail.csv"
printf '%s\n' "a,b,c" >"$write_fail"
before="$(cat "$write_fail")"
FINALIZE_CALLED=no

function csv_join_row() {
  return 1
}

function finalize_temp_file() {
  FINALIZE_CALLED=yes
  return 1
}

if state_csv_append_row "$write_fail" "a,b,c" 3 "4" "5" "6" 2>"$TMP_DIR/write-fail.err"; then
  echo "[Error] state_csv_append_row succeeded after a temp append write failure." >&2
  exit 1
fi
assert_file_equals "$before" "$write_fail"
if [ "$FINALIZE_CALLED" != "no" ]; then
  echo "[Error] state_csv_append_row finalized after a temp append write failure." >&2
  exit 1
fi

copy_fail="$TMP_DIR/copy-fail.csv"
printf '%s\n' "a,b,c" "1,2,3" >"$copy_fail"
before="$(cat "$copy_fail")"
FINALIZE_CALLED=no

if state_csv_append_row "$copy_fail" "a,b,c" 3 "4" "5" "6" 2>"$TMP_DIR/copy-fail.err"; then
  echo "[Error] state_csv_append_row succeeded after a copied-row temp write failure." >&2
  exit 1
fi
assert_file_equals "$before" "$copy_fail"
if [ "$FINALIZE_CALLED" != "no" ]; then
  echo "[Error] state_csv_append_row finalized after a copied-row temp write failure." >&2
  exit 1
fi

header_fail="$TMP_DIR/header-fail.csv"
header_tmp="$TMP_DIR/header-temp-is-dir"
printf '%s\n' "a,b,c" >"$header_fail"
mkdir -p "$header_tmp"
before="$(cat "$header_fail")"
FINALIZE_CALLED=no

function make_temp_for_file() {
  local __out_var="${1:-}"
  require_valid_var_name "$__out_var" || return 1
  printf -v "$__out_var" '%s' "$header_tmp"
  return 0
}

if state_csv_append_row "$header_fail" "a,b,c" 3 "7" "8" "9" 2>"$TMP_DIR/header-fail.err"; then
  echo "[Error] state_csv_append_row succeeded after a temp header write failure." >&2
  exit 1
fi
assert_file_equals "$before" "$header_fail"
if [ "$FINALIZE_CALLED" != "no" ]; then
  echo "[Error] state_csv_append_row finalized after a temp header write failure." >&2
  exit 1
fi

echo "[tests] state_csv_append_row.sh: PASS"
