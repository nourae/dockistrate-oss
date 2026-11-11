#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=lib/saved_settings_fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/saved_settings_fixture.sh"

source "$ROOT_DIR/tests/helpers/global_csv.sh"

function test_settings_create() {
  local requested_umask="$1" before="" candidate=""
  saved_settings_reset "create-$requested_umask"
  umask "$requested_umask"
  before="$(umask)"
  eval "$(declare -f _save_config_write_rows | sed '1s/_save_config_write_rows/settings_original_rows/')"
  function _save_config_write_rows() {
    while IFS= read -r candidate; do
      saved_settings_assert_mode "$candidate" 600
    done < <(find "$CONFIG_DIR" -type f)
    settings_original_rows
  }
  _save_config_atomic_write
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 640
  [ "$(umask)" = "$before" ] || saved_settings_fail 'Save changed caller umask'
  load_config
  [ "$NGINX_DOCKER_OPTS" = "--env 'SETTINGS_TEST_TOKEN=$SAVED_SETTINGS_MARKER'" ] ||
    saved_settings_fail 'Initial save changed the synthetic Docker option'
  saved_settings_assert_no_temps
}

function test_settings_directory_link_count() {
  local initial="$1" wanted=640 save_status=0 empty="" populated=""
  saved_settings_reset "directory-links-$initial"
  if [ "$initial" = existing ]; then
    saved_settings_seed 600
    wanted=600
  fi
  NGINX_DOCKER_OPTS='--env SETTINGS_TEST_TOKEN=DUMMY_DIRECTORY_LINKS'
  # Model filesystems that count file entries in directory st_nlink. Keep
  # native stat's device, inode, ownership and mode, and all file stats intact.
  function stat() {
    local arg="" path="" record="" children="" simulated_links=2
    local -a fields=()
    for arg in "$@"; do path="$arg"; done
    record="$(command stat "$@")" || return $?
    case "$path" in
    "$CONFIG_DIR"/.global_settings.stage.*)
      if [ -d "$path" ]; then
        IFS=' ' read -r -a fields <<<"$record"
        [ "${#fields[@]}" -eq 6 ] || return 1
        children="$(find "$path" -mindepth 1 -maxdepth 1 -type f -print)" || return 1
        [ -z "$children" ] || simulated_links=3
        record="${fields[0]} ${fields[1]} ${fields[2]} ${fields[3]} ${fields[4]} $simulated_links"
        printf '%s\n' "$record" >"$BASE_DIR/staging-links-$simulated_links"
      fi
      ;;
    esac
    printf '%s\n' "$record"
  }
  _save_config_atomic_write || save_status=$?
  [ -s "$BASE_DIR/staging-links-2" ] && [ -s "$BASE_DIR/staging-links-3" ] ||
    saved_settings_fail 'Directory link-count transition was not exercised'
  empty="$(cat "$BASE_DIR/staging-links-2")"
  populated="$(cat "$BASE_DIR/staging-links-3")"
  [ "${empty% *}" = "${populated% *}" ] ||
    saved_settings_fail 'Directory simulation changed more than its link count'
  [ "$save_status" -eq 0 ] ||
    saved_settings_fail 'Atomic save rejected a directory link-count change from 2 to 3 with stable identity and permissions'
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$wanted"
  load_config
  [ "$NGINX_DOCKER_OPTS" = '--env SETTINGS_TEST_TOKEN=DUMMY_DIRECTORY_LINKS' ] ||
    saved_settings_fail 'Directory link-count handling lost saved options'
  saved_settings_assert_no_temps
}

function test_settings_mode() {
  local mode="$1" wanted="$2" owner=""
  saved_settings_reset "mode-$mode"
  saved_settings_seed "$mode"
  owner="$(saved_settings_owner "$GLOBAL_SETTINGS_FILE")"
  NGINX_DOCKER_OPTS='--env SETTINGS_TEST_TOKEN=DUMMY_REPLACEMENT'
  _save_config_atomic_write
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$wanted"
  [ "$(saved_settings_owner "$GLOBAL_SETTINGS_FILE")" = "$owner" ] ||
    saved_settings_fail 'Save changed owner/group'
  grep -Fq DUMMY_REPLACEMENT "$GLOBAL_SETTINGS_FILE" ||
    saved_settings_fail 'Restricted settings were not updated'
}

function test_settings_owner() {
  local group="" initial_group="" owner=""
  saved_settings_reset owner
  saved_settings_seed 640
  initial_group="$(id -g)"
  if [ "$(id -u)" = 0 ]; then
    command chown "65534:$initial_group" "$GLOBAL_SETTINGS_FILE"
  else
    # Exercise a real nonprimary group where the invoking user has one.
    for group in $(id -G); do
      if [ "$group" != "$initial_group" ]; then
        command chgrp "$group" "$GLOBAL_SETTINGS_FILE"
        break
      fi
    done
  fi
  owner="$(saved_settings_owner "$GLOBAL_SETTINGS_FILE")"
  _save_config_atomic_write
  [ "$(saved_settings_owner "$GLOBAL_SETTINGS_FILE")" = "$owner" ] ||
    saved_settings_fail 'Atomic replacement lost intentional owner/group'
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 640
}

# The sourced fixture consumes these injected utility-failure selectors.
# shellcheck disable=SC2034
function test_settings_failure() {
  local failure="$1"
  saved_settings_reset "failure-$failure"
  saved_settings_seed 644
  saved_settings_snapshot
  NGINX_DOCKER_OPTS='--env SETTINGS_TEST_TOKEN=DUMMY_REJECTED'
  case "$failure" in
  chmod) SAVED_FAIL_CHMOD=__settings_temp__ ;;
  chmod-noop) SAVED_NOOP_CHMOD=__settings_temp__ ;;
  stat) SAVED_FAIL_STAT="$GLOBAL_SETTINGS_FILE" ;;
  stat-malformed) SAVED_BAD_STAT="$GLOBAL_SETTINGS_FILE" ;;
  temp-stat) SAVED_FAIL_STAT=__settings_temp__ ;;
  rename) SAVED_FAIL_MV="$GLOBAL_SETTINGS_FILE" ;;
  rename-noop) SAVED_NOOP_MV="$GLOBAL_SETTINGS_FILE" ;;
  write)
    function _save_config_write_rows() {
      printf '%s\n' "$STATE_GLOBAL_SETTINGS_HEADER" 'NGINX_DOCKER_OPTS,DUMMY_PARTIAL'
      return 1
    }
    ;;
  chown)
    # Simulate a differently owned existing file on unprivileged CI as well.
    # All reads, writes, mode changes and failure cleanup remain real.
    eval "$(declare -f _global_settings_file_metadata | sed '1s/_global_settings_file_metadata/settings_original_metadata/')"
    function _global_settings_file_metadata() {
      local record="" device="" inode="" uid="" gid="" mode="" links=""
      record="$(settings_original_metadata "$1")" || return 1
      if [ "$1" = "$GLOBAL_SETTINGS_FILE" ]; then
        IFS=' ' read -r device inode uid gid mode links <<<"$record"
        printf '%s %s %s %s %s %s\n' "$device" "$inode" "$((uid + 1))" "$gid" "$mode" "$links"
      else
        printf '%s\n' "$record"
      fi
    }
    SAVED_FAIL_CHOWN=__settings_temp__
    ;;
  esac
  if _save_config_atomic_write; then
    saved_settings_fail "Atomic save accepted $failure failure"
  fi
  case "$failure" in
  chmod | chmod-noop) [ -f "$SAVED_CHMOD_HIT" ] || saved_settings_fail 'chmod failure was not exercised' ;;
  stat | stat-malformed | temp-stat) [ -f "$SAVED_STAT_HIT" ] || saved_settings_fail 'stat failure was not exercised' ;;
  chown) [ -f "$SAVED_CHOWN_HIT" ] || saved_settings_fail 'chown failure was not exercised' ;;
  rename | rename-noop) [ -f "$SAVED_MV_HIT" ] || saved_settings_fail 'rename failure was not exercised' ;;
  esac
  saved_settings_assert_original
}

function test_settings_unsafe() {
  local kind="$1" operation="$2" external="$SAVED_SETTINGS_TEST_DIR/external-$1-$2"
  saved_settings_reset "unsafe-$kind-$operation"
  test_global_csv_seed "$external" NGINX_DOCKER_OPTS '--env SETTINGS_TEST_TOKEN=DUMMY_EXTERNAL'
  command chmod 644 "$external"
  cp "$external" "$BASE_DIR/external-before"
  case "$kind" in
  symlink) ln -s "$external" "$GLOBAL_SETTINGS_FILE" ;;
  hardlink) ln "$external" "$GLOBAL_SETTINGS_FILE" ;;
  directory) mkdir "$GLOBAL_SETTINGS_FILE" ;;
  fifo) mkfifo "$GLOBAL_SETTINGS_FILE" ;;
  esac
  if "$operation"; then
    saved_settings_fail "$operation accepted a $kind settings file"
  fi
  cmp -s "$external" "$BASE_DIR/external-before" || saved_settings_fail 'Unsafe-file rejection changed external contents'
  saved_settings_assert_mode "$external" 644
  case "$kind" in
  symlink) [ -L "$GLOBAL_SETTINGS_FILE" ] || saved_settings_fail 'Rejection replaced symlink' ;;
  hardlink) [ "$GLOBAL_SETTINGS_FILE" -ef "$external" ] || saved_settings_fail 'Rejection replaced hardlink' ;;
  directory) [ -d "$GLOBAL_SETTINGS_FILE" ] || saved_settings_fail 'Rejection replaced directory' ;;
  fifo) [ -p "$GLOBAL_SETTINGS_FILE" ] || saved_settings_fail 'Rejection replaced FIFO' ;;
  esac
  saved_settings_assert_no_temps
}

function test_settings_load_readonly() {
  saved_settings_reset load-readonly
  saved_settings_seed 666
  saved_settings_snapshot
  load_config
  saved_settings_assert_original
  [ "$NGINX_DOCKER_OPTS" = "--env 'SETTINGS_TEST_TOKEN=$SAVED_SETTINGS_MARKER'" ] ||
    saved_settings_fail 'Read-only load lost saved Docker options'
}

function test_settings_bootstrap() {
  local mode="$1" wanted="$2"
  saved_settings_reset "bootstrap-$mode"
  saved_settings_seed "$mode"
  cp "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/before.csv"
  bootstrap_config_runtime
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$wanted"
  cmp -s "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/before.csv" || saved_settings_fail 'Prepared settings were rewritten by bootstrap'
  [ ! -e "$LAST_POST_BACKUP_FILE" ] || saved_settings_fail 'Bootstrap created a transaction backup pointer'
  [ -z "$(find "$BACKUP_DIR" -name '*.tar.gz' -print)" ] || saved_settings_fail 'Bootstrap created an operator backup'
}

# The sourced fixture consumes these injected utility-failure selectors.
# shellcheck disable=SC2034
function test_settings_bootstrap_rejection() {
  local kind="$1"
  saved_settings_reset "bootstrap-reject-$kind"
  saved_settings_seed 666
  case "$kind" in
  invalid) printf '%s\n' 'HTTP_VERSION,bogus' >>"$GLOBAL_SETTINGS_FILE" ;;
  chmod) SAVED_FAIL_CHMOD="$GLOBAL_SETTINGS_FILE" ;;
  chmod-noop) SAVED_NOOP_CHMOD="$GLOBAL_SETTINGS_FILE" ;;
  stat) SAVED_FAIL_STAT="$GLOBAL_SETTINGS_FILE" ;;
  esac
  saved_settings_snapshot
  if bootstrap_config_runtime; then
    saved_settings_fail "Bootstrap accepted $kind failure"
  fi
  saved_settings_assert_original
  [ ! -e "$STATE_SCHEMA_VERSION_FILE" ] || saved_settings_fail 'Failed preflight wrote schema marker'
  [ ! -e "$BACKEND_PORTS_FILE" ] || saved_settings_fail 'Failed preflight seeded state CSV'
  [ ! -e "$(_transaction_lock_dir)" ] || saved_settings_fail 'Failed bootstrap retained its write lock'
}

function test_settings_rollback() {
  saved_settings_reset rollback
  saved_settings_seed 400
  saved_settings_snapshot
  begin_transaction_return settings_permission_rollback "$GLOBAL_SETTINGS_FILE"
  NGINX_DOCKER_OPTS='--env SETTINGS_TEST_TOKEN=DUMMY_ROLLBACK_CHANGE'
  _save_config_atomic_write
  if transaction_return_failure; then
    saved_settings_fail 'Failed transaction unexpectedly succeeded'
  fi
  saved_settings_assert_original
  [ "$NGINX_DOCKER_OPTS" = "--env 'SETTINGS_TEST_TOKEN=$SAVED_SETTINGS_MARKER'" ] ||
    saved_settings_fail 'Rollback failed to reload original Docker options'
  if transaction_is_active || [ -e "$(_transaction_lock_dir)" ]; then
    saved_settings_fail 'Rollback left active transaction state'
  fi
}

# The sourced fixture consumes the injected rename-failure selector.
# shellcheck disable=SC2034
function test_settings_partial_rename() {
  saved_settings_reset partial-rename
  saved_settings_seed 400
  saved_settings_snapshot
  SAVED_PARTIAL_MV="$GLOBAL_SETTINGS_FILE"
  NGINX_DOCKER_OPTS='--env SETTINGS_TEST_TOKEN=DUMMY_PARTIAL_RENAME'
  if save_config; then
    saved_settings_fail 'Save accepted a rename that mutated then failed'
  fi
  [ -f "$SAVED_MV_HIT" ] || saved_settings_fail 'Partial rename was not exercised'
  saved_settings_assert_original
  if transaction_is_active || [ -e "$(_transaction_lock_dir)" ]; then
    saved_settings_fail 'Failed publication retained transaction state'
  fi
}

saved_settings_run_case settings_create_umask_000 test_settings_create 000
saved_settings_run_case settings_create_umask_077 test_settings_create 077
saved_settings_run_case settings_directory_link_count_fresh test_settings_directory_link_count fresh
saved_settings_run_case settings_directory_link_count_existing test_settings_directory_link_count existing
for settings_pair in 400:400 440:440 600:600 640:640 644:640 666:640 777:640 4640:640; do
  saved_settings_run_case "settings_save_mode_${settings_pair%:*}" test_settings_mode "${settings_pair%:*}" "${settings_pair#*:}"
done
saved_settings_run_case settings_save_owner_group test_settings_owner
for settings_failure in chmod chmod-noop stat stat-malformed temp-stat rename rename-noop write chown; do
  saved_settings_run_case "settings_save_failure_$settings_failure" test_settings_failure "$settings_failure"
done
for settings_kind in symlink hardlink directory fifo; do
  saved_settings_run_case "settings_save_reject_$settings_kind" test_settings_unsafe "$settings_kind" _save_config_atomic_write
  saved_settings_run_case "settings_load_reject_$settings_kind" test_settings_unsafe "$settings_kind" load_config
done
saved_settings_run_case settings_load_readonly test_settings_load_readonly
for settings_pair in 400:400 600:600 640:640 666:640; do
  saved_settings_run_case "settings_bootstrap_mode_${settings_pair%:*}" test_settings_bootstrap "${settings_pair%:*}" "${settings_pair#*:}"
done
for settings_failure in invalid chmod chmod-noop stat; do
  saved_settings_run_case "settings_bootstrap_reject_$settings_failure" test_settings_bootstrap_rejection "$settings_failure"
done
saved_settings_run_case settings_rollback_preserves_mode test_settings_rollback
saved_settings_run_case settings_partial_rename_rolls_back test_settings_partial_rename
saved_settings_finish saved_settings_permissions.sh
