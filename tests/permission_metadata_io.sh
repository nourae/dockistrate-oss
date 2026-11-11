#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
# shellcheck source=../lib/permissions/metadata_io.sh
source "$ROOT_DIR/lib/permissions/metadata_io.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/permission-fd.XXXXXXXX")"
TEST_DIR="$(cd -- "$TEST_DIR" && pwd -P)"
trap 'permission_test_exit_status=$?; rm -rf "$TEST_DIR"; exit "$permission_test_exit_status"' EXIT

function fail() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function equal() { [ "$1" = "$2" ] || fail "$3: expected <$1>, got <$2>"; }
function rejects() { if "$@"; then fail "unexpected success: $*"; fi; }
function snapshot() {
  _secure_fs_stat_path "$1" || return 1
  printf '%s:%s:%s:%s:%s:%s\n' "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" \
    "$SECURE_FS_UID" "$SECURE_FS_GID" "$SECURE_FS_MODE" "$SECURE_FS_LINKS"
  cksum <"$1"
}
function setup_case() {
  selected="$TEST_DIR/$1/selected"
  io_parent="$selected/nested"
  file="$io_parent/fixture.key"
  outside="$TEST_DIR/$1/outside"
  sentinel="$outside/fixture.key"
  mkdir -p "$io_parent" "$outside"
  printf 'disposable fixture\n' >"$file"
  printf 'external disposable sentinel\n' >"$sentinel"
  chmod 0644 "$file" "$sentinel"
  before="$(snapshot "$sentinel")"
}
function arguments() {
  local operation="${1:-chmod}" target="${2:-$file}" root_device="" root_inode=""
  _secure_fs_stat_path "$selected" || fail 'root stat'
  root_device="$SECURE_FS_DEVICE"; root_inode="$SECURE_FS_INODE"
  _secure_fs_stat_path "$target" || fail 'entry stat'
  args=("$selected" "$root_device" "$root_inode" "$target" "$SECURE_FS_TYPE"
    "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" "$SECURE_FS_UID" "$SECURE_FS_GID"
    "$SECURE_FS_MODE" "$operation" 600 '')
  if [ "$operation" = chown ]; then args[11]="$SECURE_FS_UID"; args[12]="$SECURE_FS_GID"; fi
}
function replace_with_link() {
  if [ "$location" = leaf ]; then
    mv "$file" "$io_parent/original.key" && ln -s "$sentinel" "$file" || fail 'leaf swap'
  else
    mv "$io_parent" "$selected/original-directory" && ln -s "$outside" "$io_parent" || fail 'ancestor swap'
  fi
}
function restore_location() {
  if [ "$location" = leaf ]; then
    rm "$file" && mv "$io_parent/original.key" "$file" || fail 'restore leaf'
  else
    rm "$io_parent" && mv "$selected/original-directory" "$io_parent" || fail 'restore ancestor'
  fi
}

function test_normal_mode_and_owner() {
  arguments
  _permissions_metadata_helper_run "${args[@]}" || fail 'normal chmod'
  _secure_fs_stat_path "$file"; equal 600 "$SECURE_FS_MODE" mode
  arguments chown
  _permissions_metadata_helper_run "${args[@]}" || fail 'normal chown'
}
function test_directory_special_bits_are_exact() {
  chmod 02755 "$io_parent"
  arguments chmod "$io_parent"
  args[11]=750
  _permissions_metadata_helper_mutate "${args[@]}" || fail 'directory mutation'
  _secure_fs_stat_path "$io_parent"; equal 750 "$SECURE_FS_MODE" 'directory special bits'
}
function test_swap_before_open_is_rejected() {
  local operation="" location=""
  for operation in chmod chown; do
    for location in leaf ancestor; do
      arguments "$operation"
      replace_with_link
      rejects _permissions_metadata_helper_mutate "${args[@]}"
      equal "$before" "$(snapshot "$sentinel")" 'outside sentinel'
      restore_location
    done
  done
}
function test_swap_after_validation_cannot_redirect_syscall() {
  local operation="" location=""
  eval "$(declare -f _secure_fs_mutate_fd8 | sed '1s/_secure_fs_mutate_fd8/_real_secure_fs_mutate_fd8/')"
  function _secure_fs_mutate_fd8() {
    replace_with_link
    _secure_fs_stat_fd8 || fail 'pinned stat'
    equal "${args[6]}" "$SECURE_FS_INODE" 'pinned inode'
    _real_secure_fs_mutate_fd8 "$@"
  }
  for operation in chmod chown; do
    for location in leaf ancestor; do
      arguments "$operation"
      _permissions_metadata_helper_mutate "${args[@]}" || fail 'pinned mutation after swap'
      equal "$before" "$(snapshot "$sentinel")" 'outside sentinel'
      restore_location
    done
  done
}
function test_root_replacement_is_rejected() {
  arguments
  mv "$selected" "${selected}-original"
  ln -s "$outside" "$selected"
  rejects _permissions_metadata_helper_mutate "${args[@]}"
}
function test_regular_replacement_is_rejected() {
  arguments
  mv "$file" "$io_parent/original.key"
  printf 'replacement\n' >"$file"
  chmod 0644 "$file"
  rejects _permissions_metadata_helper_mutate "${args[@]}"
  _secure_fs_stat_path "$file"; equal 644 "$SECURE_FS_MODE" replacement
}
function test_concurrent_mode_is_preserved() {
  arguments
  chmod 0400 "$file"
  rejects _permissions_metadata_helper_mutate "${args[@]}"
  _secure_fs_stat_path "$file"; equal 400 "$SECURE_FS_MODE" 'concurrent mode'
}
function test_hardlink_is_rejected() {
  arguments
  ln "$file" "$io_parent/second-name"
  rejects _permissions_metadata_helper_mutate "${args[@]}"
}
function test_fifo_replacement_does_not_block() {
  arguments
  rm "$file"; mkfifo "$file"
  rejects _permissions_metadata_helper_mutate "${args[@]}"
}
function test_path_components_and_numeric_inputs() {
  local bad=""
  for bad in relative "$io_parent/../nested/fixture.key" "$io_parent//fixture.key" "$sentinel"; do
    arguments; args[3]="$bad"
    rejects _permissions_metadata_helper_mutate "${args[@]}"
  done
  for bad in 10000 -1 888 '600 extra'; do
    arguments; args[11]="$bad"
    rejects _permissions_metadata_helper_mutate "${args[@]}"
  done
  # An all-separator spelling is still the filesystem root. Reject before
  # pinning anything, without risking a real root metadata operation.
  function _secure_fs_pin_directory() { : >"$selected/unexpected-pin"; return 1; }
  rejects _permissions_metadata_helper_mutate //// 0 0 //// directory 0 0 0 0 755 chmod 700 ''
  [ ! -e "$selected/unexpected-pin" ] || fail 'root mutation reached directory pinning'
}
function test_missing_directories_do_not_follow_links() {
  ln -s "$outside" "$selected/link"
  rejects _permissions_metadata_helper_mkdir_plan "$selected/link/new" >/dev/null
  [ ! -e "$outside/new" ] || fail 'created outside directory'
}
function test_raced_fifo_open_is_bounded() {
  local started="$SECONDS" io_fifo_swap=true
  arguments
  eval "$(declare -f _secure_fs_stat_path | sed '1s/_secure_fs_stat_path/_real_secure_fs_stat_path/')"
  function _secure_fs_stat_path() {
    _real_secure_fs_stat_path "$@" || return $?
    if [ "$1" = ./fixture.key ] && [ "$io_fifo_swap" = true ]; then
      mv "$file" "$io_parent/original.key" && mkfifo "$file" || fail 'FIFO swap'
      io_fifo_swap=false
    fi
  }
  rejects _permissions_metadata_helper_mutate "${args[@]}"
  [ "$((SECONDS-started))" -le 8 ] || fail 'raced FIFO open exceeded bound'
}

cases=(test_normal_mode_and_owner test_directory_special_bits_are_exact
  test_swap_before_open_is_rejected test_swap_after_validation_cannot_redirect_syscall
  test_root_replacement_is_rejected test_regular_replacement_is_rejected
  test_concurrent_mode_is_preserved test_hardlink_is_rejected
  test_fifo_replacement_does_not_block test_path_components_and_numeric_inputs
  test_missing_directories_do_not_follow_links test_raced_fifo_open_is_bounded)
for name in "${cases[@]}"; do
  (
    setup_case "$name"
    "$name"
    equal "$before" "$(snapshot "$sentinel")" 'outside sentinel after test'
  ) || exit 1
  printf '%s ... ok\n' "$name"
done
printf 'Ran %s permission descriptor tests. OK\n' "${#cases[@]}"
