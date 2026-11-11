#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
source "$ROOT_DIR/lib/permissions/metadata_transaction.sh"
MODE_TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-fd-mode-tests.XXXXXXXX")"
MODE_TEST_DIR="$(cd -- "$MODE_TEST_DIR" && pwd -P)"
trap 'mode_test_status=$?; rm -rf "$MODE_TEST_DIR"; exit "$mode_test_status"' EXIT
function mode_fail() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function mode_equal() { [ "$1" = "$2" ] || mode_fail "$3: expected $1 got $2"; }
function mode_fixture() {
  mode_case="$MODE_TEST_DIR/$1"
  mode_selected="$mode_case/selected"
  mode_file="$mode_selected/fixture.key"
  mode_outside="$mode_case/outside.key"
  mkdir -p "$mode_selected"
  printf 'selected harmless fixture\n' >"$mode_file"
  printf 'outside harmless sentinel\n' >"$mode_outside"
  chmod 00600 "$mode_file"
  chmod 00644 "$mode_outside"
}
function mode_emulate_bsd() {
  # Model Darwin's utility behavior inside the real internal mutation worker.
  # Public signal/restore integration separately exercises its fresh Bash entry.
  function _permissions_metadata_helper_run() { _permissions_metadata_helper_mutate "$@"; }
  eval "$(declare -f _secure_fs_fd_chmod_intermediate | sed '1s/_secure_fs_fd_chmod_intermediate/_mode_real_intermediate/')"
  function _secure_fs_fd_chmod_intermediate() { _mode_real_intermediate "$1" "$2" bsd; }
  function chmod() {
    local mode_target="${1:-}" mode_before="" mode_boundary=""
    if [ "$#" -eq 2 ] && [ "$2" = /dev/fd/8 ]; then
      _secure_fs_stat_fd8 || return 1
      mode_before="$SECURE_FS_MODE"
      case "$mode_target" in 01400) mode_boundary=intermediate ;; 00400) mode_boundary=final ;; esac
      if [ -n "$mode_boundary" ] && [ "${mode_trigger:-}" = "before-$mode_boundary" ]; then mode_inject || return $?; fi
      # Model the verified native Darwin optimization, including zero targets.
      if [ "$((8#$mode_target))" -ne "$((8#$mode_before & 07444))" ]; then
        command chmod "$@" || return 1
      fi
      if [ -n "$mode_boundary" ] && [ "${mode_trigger:-}" = "after-$mode_boundary" ]; then mode_inject || return $?; fi
      return 0
    fi
    command chmod "$@"
  }
}
function mode_inject() {
  if [ "${mode_signal:-}" = failure ]; then return 79; fi
  : >"$mode_case/phase"
  # The supervisor cancels its worker while this owned foreground child runs.
  # The pipeline must reap it before transaction rollback starts.
  sleep 0.2
}
function test_intermediate_plan_is_narrow_and_readable() {
  local mode_row="" before="" target="" expected="" style=""
  for mode_row in bsd:600:400:1400 bsd:640:440:1440 bsd:200:0:1000 bsd:1200:1000:0 \
    gnu:600:400:none bsd:600:600:none bsd:640:400:none bsd:600:0:none; do
    IFS=: read -r style before target expected <<<"$mode_row"
    _secure_fs_fd_chmod_intermediate "$before" "$target" "$style" || mode_fail plan
    [ "$expected" != none ] || expected=""
    mode_equal "$expected" "$SECURE_FS_CHMOD_INTERMEDIATE" "$mode_row"
    if [ -n "$expected" ]; then
      [ "$((8#$expected & 0777 & ~(8#$before & 0777)))" -eq 0 ] || mode_fail 'intermediate grants access'
      [ "$((8#$expected & 06333))" -eq 0 ] || mode_fail 'intermediate grants write/execute/set-ID'
    fi
  done
  PERMISSIONS_STAT_UID=123 PERMISSIONS_STAT_GID=456 PERMISSIONS_STAT_MODE=1400
  PERMISSIONS_TXN_LAST_STATES=('123:456:600')
  PERMISSIONS_TXN_PENDING='0|chmod|123:456:600|123:456:400'
  if _permissions_transaction_state_matches 0; then mode_fail 'unplanned sticky accepted'; fi
  PERMISSIONS_TXN_PENDING="$PERMISSIONS_TXN_PENDING|123:456:1400"
  _permissions_transaction_state_matches 0 || mode_fail 'planned intermediate rejected'
  PERMISSIONS_STAT_MODE=1440
  if _permissions_transaction_state_matches 0; then mode_fail 'unplanned read bits accepted'; fi
  PERMISSIONS_STAT_MODE=1400 PERMISSIONS_STAT_UID=124
  if _permissions_transaction_state_matches 0; then mode_fail 'changed owner accepted'; fi
}
function transaction_case() {
  local mode_trigger="$1" mode_signal="$2" mode_job="" mode_pid="" mode_count=0 status=0
  mode_fixture "$mode_trigger-$mode_signal"
  mode_emulate_bsd
  if [ "$mode_signal" != failure ]; then
    eval "$(declare -f _secure_fs_supervise_body | sed '1s/_secure_fs_supervise_body/_mode_real_supervise_body/')"
    function _secure_fs_supervise_body() {
      /bin/sh -c 'printf "%s\n" "$PPID" >"$1"' _ "$mode_case/supervisor.pid"
      _mode_real_supervise_body
    }
    (
      while [ ! -s "$mode_case/supervisor.pid" ] || [ ! -e "$mode_case/phase" ]; do
        mode_count=$((mode_count+1))
        [ "$mode_count" -lt 500 ] || mode_fail 'signal phase not reached'
        sleep 0.01
      done
      IFS= read -r mode_pid <"$mode_case/supervisor.pid"
      builtin kill "-$mode_signal" "$mode_pid"
    ) &
    mode_job=$!
  fi
  PERMISSIONS_PLAN_PATHS=("$mode_file")
  PERMISSIONS_PLAN_MODES=(400)
  PERMISSIONS_PLAN_UIDS=("$(id -u)")
  PERMISSIONS_PLAN_GIDS=("$(id -g)")
  _permissions_transaction_begin "$mode_selected" || mode_fail 'transaction begin'
  _permissions_transaction_apply >"$mode_case/output" 2>"$mode_case/errors" || status=$?
  [ -z "$mode_job" ] || wait "$mode_job" || mode_fail 'signaller failed'
  [ "$status" -ne 0 ] || mode_fail 'interrupted transaction succeeded'
  _permissions_transaction_rollback >>"$mode_case/output" 2>>"$mode_case/errors" || {
    cat "$mode_case/errors" >&2; mode_fail 'intermediate rollback failed';
  }
  _secure_fs_stat_path "$mode_file" || mode_fail stat
  mode_equal 600 "$SECURE_FS_MODE" 'original mode restored'
  mode_equal "$(id -u):$(id -g)" "$SECURE_FS_UID:$SECURE_FS_GID" 'owner retained'
  sleep 0.03
  _secure_fs_stat_path "$mode_file" || mode_fail stat
  mode_equal 600 "$SECURE_FS_MODE" 'no late mutation'
  _secure_fs_stat_path "$mode_outside" || mode_fail stat
  mode_equal 644 "$SECURE_FS_MODE" 'outside mode retained'
  mode_equal 'outside harmless sentinel' "$(cat "$mode_outside")" 'outside bytes retained'
}
function swap_case() {
  local mode_location="$1"
  mode_fixture "swap-$mode_location"
  mode_emulate_bsd
  function mode_swap_callback() {
    if [ "$mode_location" = leaf ]; then
      mv "$mode_file" "$mode_selected/retained.key"
      ln -s "$mode_outside" "$mode_file"
    else
      mv "$mode_selected" "$mode_case/retained"
      mkdir "$mode_case/outside"
      ln -s "$mode_case/outside" "$mode_selected"
    fi
    _secure_fs_mutate_fd8 chmod 400 || mode_fail 'pinned intermediate mutation'
  }
  _secure_fs_with_file "$mode_file" mode_swap_callback || mode_fail 'swap callback'
  if [ "$mode_location" = leaf ]; then mode_file="$mode_selected/retained.key"; else mode_file="$mode_case/retained/fixture.key"; fi
  _secure_fs_stat_path "$mode_file" || mode_fail stat
  mode_equal 400 "$SECURE_FS_MODE" 'selected inode mutation'
  _secure_fs_stat_path "$mode_outside" || mode_fail stat
  mode_equal 644 "$SECURE_FS_MODE" 'outside mode retained'
  mode_equal 'outside harmless sentinel' "$(cat "$mode_outside")" 'outside bytes retained'
}

(test_intermediate_plan_is_narrow_and_readable) || exit 1
printf 'test_intermediate_plan_is_narrow_and_readable ... ok\n'
for mode_boundary in before-intermediate after-intermediate before-final after-final; do
  (transaction_case "$mode_boundary" failure) || exit 1
  printf 'test_failure_%s_rollback ... ok\n' "$mode_boundary"
done
for mode_boundary in after-intermediate after-final; do
  for mode_signal_name in TERM INT; do
    (transaction_case "$mode_boundary" "$mode_signal_name") || exit 1
    printf 'test_signal_%s_%s_rollback ... ok\n' "$mode_boundary" "$mode_signal_name"
  done
done
for mode_location in leaf ancestor; do
  (swap_case "$mode_location") || exit 1
  printf 'test_intermediate_%s_swap ... ok\n' "$mode_location"
done
printf 'Ran 11 descriptor mode recovery tests. OK\n'
