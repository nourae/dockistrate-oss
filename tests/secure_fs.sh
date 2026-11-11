#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
# shellcheck source=../lib/utils/secure_fs.sh
source "$ROOT_DIR/lib/utils/secure_fs.sh"
FS_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-secure-fs.XXXXXXXX")"
FS_TEST_DIR="$(cd -- "$FS_TEST_DIR" && pwd -P)"
trap 'secure_fs_test_exit_status=$?; rm -rf "$FS_TEST_DIR"; exit "$secure_fs_test_exit_status"' EXIT
function fs_fail() {
  printf '[Error] %s\n' "$*" >&2
  if [ -n "${fs_case:-}" ] && [ -f "$fs_case/errors" ]; then cat "$fs_case/errors" >&2; fi
  exit 1
}
function fs_equal() { [ "$1" = "$2" ] || fs_fail "$3: expected $1 got $2"; }
function fs_noop() { :; }

function test_stat_and_exact_directory_mode() {
  mkdir "$FS_TEST_DIR/modes"
  (
    _secure_fs_pin_directory "$FS_TEST_DIR/modes" || fs_fail pin
    chmod 02755 .
    _secure_fs_chmod_cwd 750 || fs_fail 'exact directory chmod'
    fs_equal 750 "$SECURE_FS_MODE" 'set-ID removal'
    _secure_fs_pin_directory / || fs_fail 'empty root components'
    fs_equal / "$SECURE_FS_PATH" root
  )
}
function test_pinned_cwd_survives_ancestor_swap() {
  mkdir -p "$FS_TEST_DIR/selected/nested" "$FS_TEST_DIR/outside"
  (
    _secure_fs_pin_directory "$FS_TEST_DIR/selected/nested" || fs_fail pin
    mv "$FS_TEST_DIR/selected" "$FS_TEST_DIR/retained"
    ln -s "$FS_TEST_DIR/outside" "$FS_TEST_DIR/selected"
    _secure_fs_enter_directory made create || fs_fail 'pinned mkdir'
    _secure_fs_chmod_cwd 710 || fs_fail 'pinned chmod'
  )
  [ -d "$FS_TEST_DIR/retained/nested/made" ] || fs_fail 'missing pinned result'
  [ ! -e "$FS_TEST_DIR/outside/made" ] || fs_fail 'outside creation'
}
function test_absolute_file_rejects_symlink_parent() {
  printf 'outside\n' >"$FS_TEST_DIR/outside/fixture.key"
  if _secure_fs_with_file "$FS_TEST_DIR/selected/fixture.key" fs_noop; then fs_fail 'symlink ancestor accepted'; fi
}
function test_callback_status_and_binary_stdout() {
  printf 'input\n' >"$FS_TEST_DIR/input"
  function fs_bytes() { printf 'READY\0DONE 0\n'; return 37; }
  local fs_status=0
  _secure_fs_with_file "$FS_TEST_DIR/input" fs_bytes >"$FS_TEST_DIR/output" || fs_status=$?
  fs_equal 37 "$fs_status" 'callback status'
  printf 'READY\0DONE 0\n' >"$FS_TEST_DIR/expected"
  cmp "$FS_TEST_DIR/expected" "$FS_TEST_DIR/output" || fs_fail 'callback stdout changed'
}
function test_literal_paths_and_missing_status() {
  local fs_literal="$FS_TEST_DIR/spaces [glob]"$'\n'
  mkdir "$fs_literal"
  printf 'literal\n' >"$fs_literal/fixture.key"
  (
    _secure_fs_pin_directory "$fs_literal" || fs_fail 'literal directory'
    fs_equal "$fs_literal" "$SECURE_FS_PATH" 'physical path'
    local fs_status=0
    _secure_fs_enter_directory absent allow-missing || fs_status=$?
    fs_equal 3 "$fs_status" 'missing directory status'
    _secure_fs_with_file ./fixture.key fs_noop || fs_fail 'literal file'
  )
}

function test_repeated_separators_retain_physical_guards() {
  mkdir -p "$FS_TEST_DIR/separators/nested" "$FS_TEST_DIR/separator-outside"
  printf 'harmless fixture\n' >"$FS_TEST_DIR/separators/nested/file"
  (
    _secure_fs_pin_directory "$FS_TEST_DIR//separators///nested//" || fs_fail 'repeated directory separators'
    fs_equal "$FS_TEST_DIR/separators/nested" "$SECURE_FS_PATH" 'canonical pinned directory'
    _secure_fs_with_file "$FS_TEST_DIR//separators///nested//file" fs_noop || fs_fail 'repeated file-parent separators'
    _secure_fs_pin_directory //// || fs_fail 'repeated root separators'
    fs_equal / "$SECURE_FS_PATH" 'canonical root'
    if _secure_fs_pin_directory "$FS_TEST_DIR//separators/./nested"; then fs_fail 'dot component accepted'; fi
    if _secure_fs_pin_directory "$FS_TEST_DIR//separators/../separator-outside"; then fs_fail 'dotdot component accepted'; fi
  )
  ln -s "$FS_TEST_DIR/separator-outside" "$FS_TEST_DIR/separator-link"
  if (_secure_fs_pin_directory "$FS_TEST_DIR//separator-link///made" create); then fs_fail 'separator-normalized symlink accepted'; fi
  [ ! -e "$FS_TEST_DIR/separator-outside/made" ] || fs_fail 'separator normalization bypassed no-follow guard'
}

function test_native_fd_size_and_precise_timestamps() {
  local fs_expected=""
  printf 'seven!!' >"$FS_TEST_DIR/timestamps"
  _secure_fs_stat_path "$FS_TEST_DIR/timestamps" || fs_fail 'native path stat'
  fs_expected="$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME"
  fs_equal 7 "$SECURE_FS_SIZE" 'native size'
  exec 8<"$FS_TEST_DIR/timestamps"
  _secure_fs_stat_fd8 || fs_fail 'native descriptor stat'
  exec 8<&-
  fs_equal "$fs_expected" "$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME" 'exact native timestamps'
}
function test_stat_formats_preserve_fractional_fields() {
  _secure_fs_parse_stat '1 2 3 4 81a0 1|7|2026-10-25 12:00:00.123456789 +0000|2026-10-25 12:00:00.987654321 +0000' gnu || fs_fail 'GNU format'
  fs_equal '7|2026-10-25 12:00:00.123456789 +0000|2026-10-25 12:00:00.987654321 +0000' \
    "$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME" 'GNU precision'
  _secure_fs_parse_stat '1 2 3 4 100640 1|7|1792929600.123456789|1792929600.987654321' bsd || fs_fail 'BSD format'
  fs_equal '7|1792929600.123456789|1792929600.987654321' \
    "$SECURE_FS_SIZE|$SECURE_FS_MTIME|$SECURE_FS_CTIME" 'BSD precision'
  fs_equal 640 "$SECURE_FS_MODE" 'BSD full permission mode'
  if _secure_fs_parse_stat '1 2 3 4 100640 1|7|1792929600.123456789' bsd; then fs_fail 'truncated timestamp accepted'; fi
}
function test_capability_failure_is_read_only() {
  _secure_fs_require_capabilities || fs_fail 'native capabilities'
  local fs_before="" fs_after=""
  fs_before="$(find "$FS_TEST_DIR" -print | LC_ALL=C sort)"
  function stat() {
    case "$*" in *'/dev/fd/8'*) return 95 ;; esac
    # BSD descriptor stat has no pathname argument.
    if [ "${1:-}" = -f ] && [ "$#" -eq 2 ]; then return 95; fi
    command stat "$@"
  }
  if _secure_fs_require_capabilities; then fs_fail 'missing descriptor capability accepted'; fi
  fs_after="$(find "$FS_TEST_DIR" -print | LC_ALL=C sort)"
  fs_equal "$fs_before" "$fs_after" 'capability probe changed filesystem'
}

function test_native_readonly_fd_mode_transitions() {
  local fs_before="" fs_target="" fs_exact="" fs_identity="" fs_count=0
  printf 'harmless mode fixture\n' >"$FS_TEST_DIR/fd-modes"
  chmod 00600 "$FS_TEST_DIR/fd-modes"
  exec 8<"$FS_TEST_DIR/fd-modes"
  _secure_fs_stat_fd8 || fs_fail 'initial descriptor stat'
  fs_identity="$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID"
  for fs_before in 0 200 400 600 640 1000 1200; do
    for fs_target in 0 200 400 440 600 640 1000; do
      # This private fixture stays open before testing unreadable target modes.
      printf -v fs_exact '%05o' "$((8#$fs_before))"
      chmod "$fs_exact" "$FS_TEST_DIR/fd-modes"
      _secure_fs_mutate_fd8 chmod "$fs_target" || fs_fail "native mode $fs_before to $fs_target"
      fs_equal "$fs_target" "$SECURE_FS_MODE" 'native descriptor exact mode'
      fs_equal "$fs_identity" "$SECURE_FS_DEVICE:$SECURE_FS_INODE:$SECURE_FS_UID:$SECURE_FS_GID" 'native descriptor identity'
      fs_count=$((fs_count+1))
    done
  done
  exec 8<&-
  chmod 00600 "$FS_TEST_DIR/fd-modes"
  fs_equal 49 "$fs_count" 'native mode transition count'
}

function signal_case() {
  local fs_phase="$1" fs_signal="$2" fs_case="$FS_TEST_DIR/$1-$2"
  local fs_job="" fs_pid="" fs_status=0 fs_count=0 fs_worker="" fs_expected=143
  mkdir "$fs_case"
  printf 'harmless fixture\n' >"$fs_case/fixture.key"
  chmod 0600 "$fs_case/fixture.key"
  [ "$fs_signal" != INT ] || fs_expected=130
  eval "$(declare -f _secure_fs_supervise_body | sed '1s/_secure_fs_supervise_body/_fs_real_supervise_body/')"
  eval "$(declare -f _secure_fs_file_worker | sed '1s/_secure_fs_file_worker/_fs_real_file_worker/')"
  eval "$(declare -f _secure_fs_stat_path | sed '1s/_secure_fs_stat_path/_fs_real_stat_path/')"
  function _secure_fs_supervise_body() {
    /bin/sh -c 'printf "%s\n" "$PPID" >"$1"' _ "$fs_case/supervisor.pid"
    _fs_real_supervise_body
  }
  function _secure_fs_file_worker() {
    /bin/sh -c 'printf "%s\n" "$PPID" >"$1"' _ "$fs_case/worker.pid"
    _fs_real_file_worker "$@"
  }
  function _secure_fs_stat_path() {
    _fs_real_stat_path "$@" || return $?
    if [ "$fs_phase" = blocked-open ] && [ "$1" = ./fixture.key ]; then
      mv ./fixture.key ./retained.key && mkfifo ./fixture.key || fs_fail 'FIFO swap'
      : >"$fs_case/phase"
    fi
  }
  function kill() {
    if [ "$fs_phase" = before-callback ] && [ "${1:-}" = -USR1 ] && [ ! -e "$fs_case/phase" ]; then
      : >"$fs_case/phase"
      while :; do sleep 0.01; done
    fi
    builtin kill "$@"
  }
  function fs_callback() {
    if [ "$fs_phase" = metadata-child ]; then
      "$BASH" --noprofile --norc -c 'source "$2/lib/utils/secure_fs.sh"; : >"$1/phase"; sleep 0.2; _secure_fs_mutate_fd8 chmod 400 && : >"$1/child-finished"' _ "$fs_case" "$ROOT_DIR"
    else
      : >"$fs_case/callback-started"
    fi
  }
  # Keep the tested pipeline in the foreground. Bash 3 intentionally ignores
  # SIGINT in asynchronous jobs; only this disposable signaller is backgrounded.
  (
    while [ ! -s "$fs_case/supervisor.pid" ] || [ ! -s "$fs_case/worker.pid" ] || [ ! -e "$fs_case/phase" ]; do
      fs_count=$((fs_count+1))
      [ "$fs_count" -lt 300 ] || fs_fail "signal phase never reached: $fs_phase"
      sleep 0.01
    done
    IFS= read -r fs_pid <"$fs_case/supervisor.pid"
    builtin kill "-$fs_signal" "$fs_pid" || fs_fail 'signal supervisor'
  ) &
  fs_job=$!
  _secure_fs_with_file "$fs_case/fixture.key" fs_callback >"$fs_case/output" 2>"$fs_case/errors" || fs_status=$?
  wait "$fs_job" || fs_fail 'signaller failed'
  IFS= read -r fs_pid <"$fs_case/supervisor.pid"
  IFS= read -r fs_worker <"$fs_case/worker.pid"
  fs_equal "$fs_expected" "$fs_status" 'signal result'
  if builtin kill -0 "$fs_pid" 2>/dev/null || builtin kill -0 "$fs_worker" 2>/dev/null; then
    fs_fail 'pipeline returned with a live worker'
  fi
  if [ "$fs_phase" = metadata-child ]; then
    [ -e "$fs_case/child-finished" ] || fs_fail 'rollback could run before metadata child finished'
    _secure_fs_stat_path "$fs_case/fixture.key" || fs_fail stat
    fs_equal 400 "$SECURE_FS_MODE" 'child completed mutation'
    chmod 00600 "$fs_case/fixture.key"
    sleep 0.05
    _secure_fs_stat_path "$fs_case/fixture.key" || fs_fail stat
    fs_equal 600 "$SECURE_FS_MODE" 'no late mutation after recovery'
  else
    [ ! -e "$fs_case/callback-started" ] || fs_fail 'cancelled open began callback'
  fi
}

for fs_name in test_stat_and_exact_directory_mode test_pinned_cwd_survives_ancestor_swap \
  test_absolute_file_rejects_symlink_parent test_callback_status_and_binary_stdout \
  test_literal_paths_and_missing_status test_repeated_separators_retain_physical_guards \
  test_native_fd_size_and_precise_timestamps \
  test_stat_formats_preserve_fractional_fields test_capability_failure_is_read_only \
  test_native_readonly_fd_mode_transitions; do
  ("$fs_name") || exit 1
  printf '%s ... ok\n' "$fs_name"
done
for fs_phase in blocked-open before-callback metadata-child; do
  for fs_signal in TERM INT; do
    (signal_case "$fs_phase" "$fs_signal") || exit 1
    printf 'test_signal_%s_%s ... ok\n' "$fs_phase" "$fs_signal"
  done
done
printf 'Ran 16 secure filesystem tests. OK\n'
