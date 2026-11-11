#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/utils/fs.sh
source "$ROOT_DIR/lib/utils/fs.sh"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"

function fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function same_record() {
  cmp -s "$CASE_DIR/expected" "$CASE_DIR/actual" || fail "$1"
}

function path_forms() {
  PATHS=(
    "$CASE_DIR/plain" "$CASE_DIR/with spaces" "$CASE_DIR/*?[glob]"
    "$CASE_DIR/-option" "$CASE_DIR/"$'leaf\n\n' "$CASE_DIR/"$'leaf\r\t'
    "$CASE_DIR/"$'parent\n\n/leaf\n' "$CASE_DIR/"$'parent\r\t/leaf'
    "/dockistrate-path-split-$$" / // /// "$CASE_DIR/plain/" "$CASE_DIR/plain///"
    "$CASE_DIR//plain" "/$CASE_DIR/plain" "$CASE_DIR/./plain" "$CASE_DIR/../plain"
    leaf ./leaf ../leaf relative/leaf relative//leaf relative/leaf/// ./-option
    $'relative\n/leaf\n\n' $'relative//leaf\n'
  )
}

# Utilities provide the independent native GNU/BSD byte oracle. The sentinel
# protects filename newlines, removing only the utility's output delimiter.
function expected_split() {
  EXPECTED_DIR="$(command dirname "$1" && printf '.')" || fail 'dirname oracle failed'
  EXPECTED_DIR="${EXPECTED_DIR%$'\n.'}"
  EXPECTED_BASE="$(command basename "$1" && printf '.')" || fail 'basename oracle failed'
  EXPECTED_BASE="${EXPECTED_BASE%$'\n.'}"
}

function observe_guards() {
  function runtime_state_path_guard_if_declared() {
    printf 'guard\0%s\0%s\0' "$1" "$2" >>"$CASE_DIR/actual"
  }
}

function temp_path_bytes() {
  local path result original_umask
  path_forms
  observe_guards
  function mktemp() {
    printf 'mktemp\0%s\0%s\0' "$1" "$(umask)" >>"$CASE_DIR/actual"
    printf '%s\n' "$CASE_DIR/fake-temp"
  }
  umask 027
  original_umask="$(umask)"
  for path in "${PATHS[@]}"; do
    expected_split "$path"
    printf 'guard\0%s\0temp file directory\0guard\0%s\0temp file target\0mktemp\0%s\0%s\0' \
      "$EXPECTED_DIR" "$path" "$EXPECTED_DIR/.$EXPECTED_BASE.tmp.XXXXXX" \
      "$(umask 077; umask)" >"$CASE_DIR/expected"
    : >"$CASE_DIR/actual"
    result=unchanged
    make_temp_for_file result "$path" >"$CASE_DIR/stdout"
    same_record 'temp path, guard order or creation umask differs from native utilities'
    [ "$result" = "$CASE_DIR/fake-temp" ] || fail 'temp output variable changed'
    [ ! -s "$CASE_DIR/stdout" ] || fail 'temp helper wrote unexpected stdout'
    [ "$(umask)" = "$original_umask" ] || fail 'temp helper did not restore umask'
  done
}

function csv_guard_path_bytes() {
  local path
  path_forms
  observe_guards
  for path in "${PATHS[@]}"; do
    expected_split "$path"
    printf 'guard\0%s\0probe directory\0guard\0%s\0probe\0' "$EXPECTED_DIR" "$path" >"$CASE_DIR/expected"
    : >"$CASE_DIR/actual"
    _csv_runtime_state_guard_file_and_dir_if_declared "$path" probe
    same_record 'CSV guard directory or exact filename differs from native dirname'
  done
}

function csv_header_path_bytes() {
  local path
  path_forms
  observe_guards
  function mkdir() { printf 'mkdir\0%s\0%s\0' "$1" "$2" >>"$CASE_DIR/actual"; }
  function _csv_write_header_file() { printf 'header\0%s\0%s\0%s\0' "$1" "$2" "$3" >>"$CASE_DIR/actual"; }
  for path in "${PATHS[@]}"; do
    expected_split "$path"
    {
      printf 'guard\0%s\0CSV file directory\0guard\0%s\0CSV file\0' "$EXPECTED_DIR" "$path"
      printf 'mkdir\0-p\0%s\0' "$EXPECTED_DIR"
      printf 'guard\0%s\0CSV file directory\0guard\0%s\0CSV file\0' "$EXPECTED_DIR" "$path"
      printf 'header\0%s\0one,two\0already_guarded\0' "$path"
    } >"$CASE_DIR/expected"
    : >"$CASE_DIR/actual"
    csv_require_header "$path" one,two
    same_record 'CSV mkdir, guard sequence or header path differs from native dirname'
  done
}

function temp_guard_failure() {
  local path result index
  function runtime_state_path_guard_if_declared() {
    GUARD_COUNT=$((GUARD_COUNT + 1))
    [ "$GUARD_COUNT" -ne "$FAIL_GUARD" ]
  }
  function mktemp() { : >"$CASE_DIR/unexpected-mktemp"; return 17; }
  for path in "$CASE_DIR/plain" "$CASE_DIR//fallback"; do
    for index in 1 2; do
      GUARD_COUNT=0 FAIL_GUARD="$index" result=unchanged
      if make_temp_for_file result "$path"; then fail 'temp guard failure accepted'; fi
      [ "$result" = unchanged ] || fail 'temp guard failure published an output'
      [ "$GUARD_COUNT" -eq "$index" ] || fail 'temp guards continued after rejection'
      [ ! -e "$CASE_DIR/unexpected-mktemp" ] || fail 'temp creation ran after a rejected guard'
    done
  done
}

function temp_mktemp_failure() {
  local path result original_umask
  function mktemp() { printf '%s\n' partial-output; return 17; }
  umask 027
  original_umask="$(umask)"
  for path in "$CASE_DIR/plain" "$CASE_DIR//fallback"; do
    result=unchanged
    if make_temp_for_file result "$path" >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"; then fail 'mktemp failure accepted'; fi
    [ "$result" = unchanged ] || fail 'mktemp failure published an output'
    [ "$(umask)" = "$original_umask" ] || fail 'mktemp failure did not restore umask'
    [ ! -s "$CASE_DIR/stdout" ] || fail 'mktemp failure leaked partial output'
    [ -s "$CASE_DIR/stderr" ] || fail 'mktemp failure omitted its diagnostic'
  done
}

function csv_guard_failure() {
  local path index
  function runtime_state_path_guard_if_declared() {
    GUARD_COUNT=$((GUARD_COUNT + 1))
    [ "$GUARD_COUNT" -ne "$FAIL_GUARD" ]
  }
  function mkdir() { MKDIR_COUNT=$((MKDIR_COUNT + 1)); }
  function _csv_write_header_file() { fail 'header published after a rejected guard'; }
  for path in "$CASE_DIR/plain" "$CASE_DIR//fallback"; do
    for index in 1 2 3 4; do
      GUARD_COUNT=0 MKDIR_COUNT=0 FAIL_GUARD="$index"
      if csv_require_header "$path" one,two; then fail 'CSV guard failure accepted'; fi
      [ "$GUARD_COUNT" -eq "$index" ] || fail 'CSV guards continued after rejection'
      if [ "$index" -le 2 ]; then
        [ "$MKDIR_COUNT" -eq 0 ] || fail 'mkdir ran before guard acceptance'
      else
        [ "$MKDIR_COUNT" -eq 1 ] || fail 'post-mkdir guards were not reached'
      fi
    done
  done
}

function csv_mkdir_failure() {
  local path
  observe_guards
  function mkdir() { return 17; }
  function _csv_write_header_file() { fail 'header published after failed mkdir'; }
  for path in "$CASE_DIR/plain" "$CASE_DIR//fallback"; do
    : >"$CASE_DIR/actual"
    if csv_require_header "$path" one,two >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"; then fail 'CSV mkdir failure accepted'; fi
    [ ! -s "$CASE_DIR/stdout" ] || fail 'CSV mkdir failure wrote stdout'
    [ -s "$CASE_DIR/stderr" ] || fail 'CSV mkdir failure omitted its diagnostic'
  done
}

function fallback_utility_failures() {
  local result
  function dirname() { printf '%s\n' partial-output; return 17; }
  function mktemp() { : >"$CASE_DIR/unexpected-mktemp"; return 17; }
  function mkdir() { fail 'directory creation ran after failed dirname'; }
  result=unchanged
  if make_temp_for_file result relative/leaf; then fail 'dirname failure accepted for temp'; fi
  [ "$result" = unchanged ] || fail 'dirname failure published a temp output'
  if _csv_runtime_state_guard_file_and_dir_if_declared relative/leaf; then fail 'dirname failure accepted for CSV guard'; fi
  if csv_require_header relative/leaf one,two; then fail 'dirname failure accepted for CSV header'; fi
  unset -f dirname
  function basename() { printf '%s\n' partial-output; return 17; }
  if make_temp_for_file result relative/leaf; then fail 'basename failure accepted for temp'; fi
  [ "$result" = unchanged ] || fail 'basename failure published a temp output'
  [ ! -e "$CASE_DIR/unexpected-mktemp" ] || fail 'temp creation ran after a failed utility'
  unset -f basename mktemp mkdir
}

function expected_failure_traps() {
  local before after
  trap 'printf ERR >>"$CASE_DIR/traps"' ERR
  before="$(trap -p ERR)"
  fallback_utility_failures
  temp_mktemp_failure
  after="$(trap -p ERR)"
  [ "$before" = "$after" ] || fail 'expected failure changed caller ERR handler'
}

function real_atomic_and_csv_paths() {
  local name path result original_umask
  # Use the real guards and filesystem only inside this disposable state tree.
  # shellcheck source=../lib/runtime_paths.sh
  source "$ROOT_DIR/lib/runtime_paths.sh"
  STATE_DIR="$CASE_DIR/state"
  mkdir -p "$STATE_DIR/"$'parent\n'
  umask 027
  original_umask="$(umask)"
  for name in plain 'with spaces' '*?[glob]' '-option' $'leaf\n\n' $'leaf\r\t'; do
    path="$STATE_DIR/"$'parent\n/'"$name"
    result=''
    make_temp_for_file result "$path"
    [ -f "$result" ] || fail 'real temp was not created'
    [[ "$result" == "$STATE_DIR/"$'parent\n/.'"$name".tmp.* ]] || fail 'real temp changed literal filename bytes'
    printf 'one,two\n' >"$result"
    finalize_temp_file "$path" "$result"
    csv_require_header "$path" one,two
    printf 'one,two\n' >"$CASE_DIR/expected"
    cmp -s "$CASE_DIR/expected" "$path" || fail 'atomic write changed target content'
    rm "$path"
    csv_require_header "$path" one,two
    cmp -s "$CASE_DIR/expected" "$path" || fail 'new CSV header changed literal target or content'
    [ "$(umask)" = "$original_umask" ] || fail 'real write changed caller umask'
  done
}

CASES=(temp_path_bytes csv_guard_path_bytes csv_header_path_bytes temp_guard_failure temp_mktemp_failure csv_guard_failure csv_mkdir_failure fallback_utility_failures expected_failure_traps real_atomic_and_csv_paths)
if [ "${1:-}" = --case ]; then
  CASE_DIR="${2:?case directory required}"
  case_name="${3:?case name required}"
  cd "$CASE_DIR"
  "$case_name"
  exit 0
fi
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-path-split.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
for case_name in "${CASES[@]}"; do
  CASE_DIR="$FIXTURE/$case_name"
  mkdir "$CASE_DIR"
  if ! "$BASH" "$0" --case "$CASE_DIR" "$case_name" >"$CASE_DIR/output" 2>&1; then
    cat "$CASE_DIR/output" >&2
    fail "path split case failed: $case_name"
  fi
  if [ -s "$CASE_DIR/output" ]; then
    cat "$CASE_DIR/output" >&2
    fail "path split case produced unexpected output: $case_name"
  fi
  printf '[tests] path-split PASS: %s\n' "$case_name"
done
printf 'Path splitting checks passed (10 cases).\n'
