#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=lib/saved_settings_fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/saved_settings_fixture.sh"

# Production serialization consumes the configured synthetic Docker option.
# shellcheck disable=SC2034
function settings_restore_fixture() {
  local label="$1" incoming_mode="${2:-644}"
  saved_settings_reset "restore-$label"
  saved_settings_seed 400
  saved_settings_snapshot
  BACKUP_SOURCE="$BASE_DIR/restore-source"
  mkdir -p "$BACKUP_SOURCE/config"
  NGINX_DOCKER_OPTS='--env SETTINGS_TEST_TOKEN=DUMMY_RESTORED'
  _save_config_write_rows >"$BACKUP_SOURCE/config/global_settings.csv"
  command chmod "$incoming_mode" "$BACKUP_SOURCE/config/global_settings.csv"
  cp "$BACKUP_SOURCE/config/global_settings.csv" "$BASE_DIR/candidate-before.csv"
  SETTINGS_CANDIDATE_MODE="$incoming_mode"
  load_config
  SAVED_BEGIN_TXN_HIT="$BASE_DIR/begin.hit"
  SAVED_RENDER_HIT="$BASE_DIR/render.hit"
  eval "$(declare -f begin_transaction | sed '1s/begin_transaction/settings_original_begin/')"
  function begin_transaction() {
    : >"$SAVED_BEGIN_TXN_HIT"
    settings_original_begin "$@"
  }
  function update_nginx_config() {
    local mode=""
    : >"$SAVED_RENDER_HIT"
    mode="$(trap - ERR EXIT; saved_settings_mode "$GLOBAL_SETTINGS_FILE")" || return 1
    [ "$((8#$mode & 8#137))" -eq 0 ] ||
      saved_settings_fail 'Restore reached rendering with excessive settings permissions'
  }
}

function settings_restore_assert_candidate_unchanged() {
  cmp -s "$BACKUP_SOURCE/config/global_settings.csv" "$BASE_DIR/candidate-before.csv" ||
    saved_settings_fail 'Restore modified the operator-owned candidate'
  saved_settings_assert_mode "$BACKUP_SOURCE/config/global_settings.csv" "$SETTINGS_CANDIDATE_MODE"
}

function test_settings_restore_directory() {
  local mode="$1" wanted="$2"
  settings_restore_fixture "directory-${3:-$mode}" "$mode"
  umask 000
  # Observe both sides of the actual publication copy, rather than only its
  # eventual mode after fix-permissions has run.
  function cp() {
    local arg="" previous="" target="" stage="" observed=""
    for arg in "$@"; do previous="$target"; target="$arg"; done
    if [ "$target" = "$CONFIG_DIR/" ]; then
      stage="${previous%/.}/global_settings.csv"
      trap -p ERR EXIT >"$BASE_DIR/observer-traps.before"
      grep -Fq _rollback_handler "$BASE_DIR/observer-traps.before" ||
        saved_settings_fail 'Publication observer ran without active rollback traps'
      observed="$(trap - ERR EXIT; saved_settings_mode "$stage")" || return 1
      trap -p ERR EXIT >"$BASE_DIR/observer-traps.after"
      cmp -s "$BASE_DIR/observer-traps.before" "$BASE_DIR/observer-traps.after" ||
        saved_settings_fail 'Metadata observation changed the parent rollback traps'
      [ "$((8#$observed & 8#137))" -eq 0 ] ||
        saved_settings_fail 'Restore published permissive staged settings'
      command cp "$@" || return 1
      saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$wanted"
      return 0
    fi
    command cp "$@"
  }
  restore_backup "$BACKUP_SOURCE"
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$wanted"
  grep -Fq DUMMY_RESTORED "$GLOBAL_SETTINGS_FILE" || saved_settings_fail 'Restore did not publish incoming settings'
  [ -f "$SAVED_RENDER_HIT" ] || saved_settings_fail 'Restore did not reach rendering'
  [ ! -e "$(_transaction_lock_dir)" ] || saved_settings_fail 'Restore retained its transaction lock'
  settings_restore_assert_candidate_unchanged
}

function test_settings_restore_stat_probe() {
  local probe_bin="$SAVED_SETTINGS_TEST_DIR/stat-probe-bin"
  mkdir -p "$probe_bin"
  SAVED_SETTINGS_REAL_STAT="$(type -P stat)" || return 1
  SAVED_SETTINGS_STAT_STYLE=bsd
  if "$SAVED_SETTINGS_REAL_STAT" -c '%a' "$probe_bin" >/dev/null 2>&1; then
    SAVED_SETTINGS_STAT_STYLE=gnu
  fi
  SAVED_SETTINGS_STAT_BEGIN="$SAVED_SETTINGS_TEST_DIR/restore-directory-stat-probe/begin.hit"
  SAVED_SETTINGS_STAT_HITS="$probe_bin"
  export SAVED_SETTINGS_REAL_STAT SAVED_SETTINGS_STAT_STYLE SAVED_SETTINGS_STAT_BEGIN SAVED_SETTINGS_STAT_HITS
  # Exercise the entire BSD stat surface, including production metadata and
  # backup-signature probes during the real transaction. Values always come
  # from the external host tool, including full mode bits and nanoseconds.
  cat >"$probe_bin/stat" <<'STAT'
#!/usr/bin/env bash
set -Eeuo pipefail
original=("$@")
flags=()
if [ "${1:-}" = -L ]; then flags=(-L); shift; fi
format="${2:-}"
if [ "${1:-}" = -c ]; then
  if [ -f "$SAVED_SETTINGS_STAT_BEGIN" ]; then
    printf '%s\n' "$format" >>"$SAVED_SETTINGS_STAT_HITS/gnu-probe"
  fi
  exit 1
fi
[ "${1:-}" = -f ] || exit 2
shift 2
if [ -f "$SAVED_SETTINGS_STAT_BEGIN" ]; then
  printf '%s\n' "$format" >>"$SAVED_SETTINGS_STAT_HITS/bsd-fallback"
  if [ "$#" -eq 0 ]; then printf '%s\n' "$format" >>"$SAVED_SETTINGS_STAT_HITS/bsd-stdin"; fi
fi
if [ "$SAVED_SETTINGS_STAT_STYLE" = bsd ]; then
  exec "$SAVED_SETTINGS_REAL_STAT" "${original[@]}"
fi
# GNU stat names stdin "-", whereas BSD stat uses it when no path is given.
if [ "$#" -eq 0 ]; then set -- -; fi
case "$format" in
'%Lp') gnu_format='%a' ;;
'%p') gnu_format='%f' ;;
'%l') gnu_format='%h' ;;
'%u:%g' | '%d:%i') gnu_format="$format" ;;
'%d %i %u %g %p %l') gnu_format='%d %i %u %g %f %h' ;;
'%d %i %u %g %p %l|%z|%.9Fm|%.9Fc') gnu_format='%d %i %u %g %f %h|%s|%Y|%y|%Z|%z' ;;
'%d:%i:%z:%m:%c') gnu_format='%d:%i:%s:%Y:%Z' ;;
'%d:%i:%z:%m:%c:%p') gnu_format='%d:%i:%s:%Y:%Z:%f' ;;
'%p|%.9Fm') gnu_format='%f|%Y|%y' ;;
'%m') gnu_format='%Y' ;;
*)
  printf 'Unsupported BSD stat fixture format: %s\n' "$format" >&2
  exit 2
  ;;
esac
"$SAVED_SETTINGS_REAL_STAT" ${flags[@]+"${flags[@]}"} -c "$gnu_format" -- "$@" |
  while IFS= read -r record; do
    case "$format" in
    '%Lp') printf '%o\n' "$((8#$record & 8#777))" ;;
    '%p') printf '%o\n' "$((16#$record))" ;;
    '%d %i %u %g %p %l')
      read -r device inode uid gid mode links <<<"$record"
      printf '%s %s %s %s %o %s\n' "$device" "$inode" "$uid" "$gid" "$((16#$mode))" "$links"
      ;;
    '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc')
      IFS='|' read -r metadata size mtime_seconds mtime_timestamp ctime_seconds ctime_timestamp <<<"$record"
      read -r device inode uid gid mode links <<<"$metadata"
      mtime_nanos="${mtime_timestamp#*.}"; mtime_nanos="${mtime_nanos%% *}"
      ctime_nanos="${ctime_timestamp#*.}"; ctime_nanos="${ctime_nanos%% *}"
      case "$mtime_nanos:$ctime_nanos" in *[!0-9:]* | :* | *:) exit 2 ;; esac
      [ "${#mtime_nanos}" -eq 9 ] && [ "${#ctime_nanos}" -eq 9 ] || exit 2
      printf '%s %s %s %s %o %s|%s|%s.%s|%s.%s\n' \
        "$device" "$inode" "$uid" "$gid" "$((16#$mode))" "$links" "$size" \
        "$mtime_seconds" "$mtime_nanos" "$ctime_seconds" "$ctime_nanos"
      ;;
    '%d:%i:%z:%m:%c:%p')
      printf '%s:%o\n' "${record%:*}" "$((16#${record##*:}))"
      ;;
    '%p|%.9Fm')
      IFS='|' read -r mode seconds timestamp <<<"$record"
      nanos="${timestamp#*.}"
      nanos="${nanos%% *}"
      printf '%o|%s.%s\n' "$((16#$mode))" "$seconds" "$nanos"
      ;;
    *) printf '%s\n' "$record" ;;
    esac
  done
STAT
  command chmod 700 "$probe_bin/stat"
  PATH="$probe_bin:$PATH" test_settings_restore_directory 644 640 stat-probe
  grep -Fxq '%a' "$probe_bin/gnu-probe" &&
    grep -Fxq '%d %i %u %g %a %h' "$probe_bin/gnu-probe" &&
    grep -Fxq '%Lp' "$probe_bin/bsd-fallback" &&
    grep -Fxq '%d %i %u %g %p %l' "$probe_bin/bsd-fallback" &&
    grep -Fxq '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc' "$probe_bin/bsd-fallback" &&
    grep -Fxq '%d %i %u %g %p %l|%z|%.9Fm|%.9Fc' "$probe_bin/bsd-stdin" ||
    saved_settings_fail 'Active restore did not exercise both mode and metadata BSD fallbacks'
}

function test_settings_restore_archive() {
  settings_restore_fixture archive 640
  # Supported archives have one backup directory containing config/.
  tar -czf "$BASE_DIR/settings.tar.gz" -C "$BASE_DIR" "$(basename "$BACKUP_SOURCE")"
  umask 077
  restore_backup "$BASE_DIR/settings.tar.gz"
  # Archive intake intentionally applies its private umask. Do not recreate
  # group access that the archive's staging policy has already removed.
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 600
  grep -Fq DUMMY_RESTORED "$GLOBAL_SETTINGS_FILE" || saved_settings_fail 'Archive restore lost incoming settings'
  settings_restore_assert_candidate_unchanged
}

# The sourced fixture consumes these injected utility-failure selectors.
# shellcheck disable=SC2034
function test_settings_restore_preflight_failure() {
  local failure="$1"
  settings_restore_fixture "preflight-$failure" 666
  # Intake first copies the candidate's mode. Fail only the subsequent
  # protection operation, not that initial chmod on an already-private copy.
  SAVED_CHMOD_REQUIRED_MODE=640
  case "$failure" in
  chmod) SAVED_FAIL_CHMOD="$TMP_DIR/restore_*/directory/config/global_settings.csv" ;;
  chmod-noop) SAVED_NOOP_CHMOD="$TMP_DIR/restore_*/directory/config/global_settings.csv" ;;
  stat) SAVED_FAIL_STAT="$TMP_DIR/restore_*/directory/config/global_settings.csv" ;;
  esac
  if restore_backup "$BACKUP_SOURCE"; then
    saved_settings_fail "Restore accepted staged $failure failure"
  fi
  case "$failure" in
  chmod | chmod-noop) [ -f "$SAVED_CHMOD_HIT" ] || saved_settings_fail 'Restore chmod failure was not exercised' ;;
  stat) [ -f "$SAVED_STAT_HIT" ] || saved_settings_fail 'Restore stat failure was not exercised' ;;
  esac
  saved_settings_assert_original
  [ ! -e "$SAVED_BEGIN_TXN_HIT" ] || saved_settings_fail 'Unsafe candidate reached the transaction'
  [ ! -e "$SAVED_RENDER_HIT" ] || saved_settings_fail 'Unsafe candidate reached rendering'
  settings_restore_assert_candidate_unchanged
}

function test_settings_restore_postcopy_failure() {
  settings_restore_fixture postcopy 644
  eval "$(declare -f _restore_backup_verify_settings_permissions | sed '1s/_restore_backup_verify_settings_permissions/settings_original_restore_verify/')"
  function _restore_backup_verify_settings_permissions() {
    if [ "$1" = "$GLOBAL_SETTINGS_FILE" ] && [ ! -e "$BASE_DIR/verify.hit" ]; then
      : >"$BASE_DIR/verify.hit"
      return 1
    fi
    settings_original_restore_verify "$@"
  }
  if (restore_backup "$BACKUP_SOURCE"); then
    saved_settings_fail 'Restore accepted post-copy verification failure'
  fi
  [ -e "$BASE_DIR/verify.hit" ] || saved_settings_fail 'Post-copy verification failure was not exercised'
  saved_settings_assert_original
  [ ! -e "$SAVED_RENDER_HIT" ] || saved_settings_fail 'Unverified live settings reached rendering'
  [ ! -e "$(_transaction_lock_dir)" ] || saved_settings_fail 'Failed restore retained its lock'
}

function test_settings_restore_late_failure() {
  settings_restore_fixture late-failure 644
  function update_nginx_config() { : >"$SAVED_RENDER_HIT"; return 1; }
  if (restore_backup "$BACKUP_SOURCE"); then
    saved_settings_fail 'Restore accepted config-render failure'
  fi
  [ -e "$SAVED_RENDER_HIT" ] || saved_settings_fail 'Late restore failure was not exercised'
  saved_settings_assert_original
  [ ! -e "$(_transaction_lock_dir)" ] || saved_settings_fail 'Failed restore retained its lock'
}

function test_settings_repair() {
  local mode="$1" wanted="$2"
  saved_settings_reset "repair-$mode"
  saved_settings_seed "$mode"
  cp "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/before.csv"
  fix_permissions "$CONFIG_DIR"
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" "$wanted"
  cmp -s "$GLOBAL_SETTINGS_FILE" "$BASE_DIR/before.csv" || saved_settings_fail 'Permission repair changed settings contents'
}

# Inject the repair failure at its descriptor boundary; save/restore staging
# above still exercises the ordinary chmod failure selectors in the fixture.
# shellcheck disable=SC2034
function test_settings_repair_failure() {
  saved_settings_reset repair-failure
  saved_settings_seed 666
  saved_settings_snapshot
  SAVED_FAIL_CHMOD="$GLOBAL_SETTINGS_FILE"
  eval "$(declare -f _permissions_metadata_mutate_fd | sed '1s/_permissions_metadata_mutate_fd/settings_original_metadata_mutate_fd/')"
  function _permissions_metadata_mutate_fd() {
    if [ "$2" = chmod ] && saved_settings_matches "${PERMISSIONS_TXN_PATHS[$1]}" "$SAVED_FAIL_CHMOD"; then
      : >"$SAVED_CHMOD_HIT"
      return 1
    fi
    settings_original_metadata_mutate_fd "$@"
  }
  if fix_permissions "$CONFIG_DIR"; then
    saved_settings_fail 'Permission repair ignored settings chmod failure'
  fi
  [ -e "$SAVED_CHMOD_HIT" ] || saved_settings_fail 'Repair failure was not exercised'
  saved_settings_assert_original
}

saved_settings_run_case settings_restore_directory_644 test_settings_restore_directory 644 640
saved_settings_run_case settings_restore_directory_400 test_settings_restore_directory 400 400
saved_settings_run_case settings_restore_directory_640 test_settings_restore_directory 640 640
saved_settings_run_case settings_restore_stat_fallback_transaction test_settings_restore_stat_probe
saved_settings_run_case settings_restore_archive_private_umask test_settings_restore_archive
for settings_failure in chmod chmod-noop stat; do
  saved_settings_run_case "settings_restore_preflight_$settings_failure" test_settings_restore_preflight_failure "$settings_failure"
done
saved_settings_run_case settings_restore_postcopy_rollback test_settings_restore_postcopy_failure
saved_settings_run_case settings_restore_late_rollback test_settings_restore_late_failure
for settings_pair in 400:400 600:600 640:640 666:640; do
  saved_settings_run_case "settings_repair_mode_${settings_pair%:*}" test_settings_repair "${settings_pair%:*}" "${settings_pair#*:}"
done
saved_settings_run_case settings_repair_failure_atomic test_settings_repair_failure
saved_settings_finish saved_settings_permissions_restore.sh
