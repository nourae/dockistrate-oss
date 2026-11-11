#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-permission-startup.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
ORIGINAL_PATH="$PATH"

function fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function equal() {
  [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$1], got [$2]"
}

function load_helpers() {
  # shellcheck source=../lib/permissions/common.sh
  source "$ROOT_DIR/lib/permissions/common.sh"
  # shellcheck source=../lib/permissions/metadata_transaction.sh
  source "$ROOT_DIR/lib/permissions/metadata_transaction.sh"
}

function mock_stat() {
  local directory="$1" dialect="$2"
  mkdir -p "$directory"
  {
    printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nDIALECT=%s\n' "$dialect"
    cat <<'MOCK'
printf '%s\n' "${1:-}" >>"$STAT_TRACE"
if [ "${MOCK_FAIL:-false}" = true ]; then
  printf 'failed probe output\n'
  exit 42
fi
case "$DIALECT:${1:-}" in gnu:-c | bsd:-f) ;; *) exit 1 ;; esac
format="${2:-}"
shift 2
for path in "$@"; do
  case "$format" in
  '%a') printf '%s\n' "${MOCK_MODE:-600}" ;;
  '%p')
    if [ "${MOCK_FULL_MODE+x}" = x ]; then printf '%s\n' "$MOCK_FULL_MODE"
    else printf '%o\n' "$((8#100000 | 8#${MOCK_MODE:-600}))"; fi
    ;;
  '%h' | '%l') printf '%s\n' "${MOCK_LINKS:-1}" ;;
  '%d %i %u %g %a %h') printf '1 2 3 4 %s %s\n' "${MOCK_MODE:-600}" "${MOCK_LINKS:-1}" ;;
  '%d %i %u %g %p %l')
    if [ "${MOCK_FULL_MODE+x}" = x ]; then mode="$MOCK_FULL_MODE"
    else printf -v mode '%o' "$((8#100000 | 8#${MOCK_MODE:-600}))"; fi
    printf '1 2 3 4 %s %s\n' "$mode" "${MOCK_LINKS:-1}"
    ;;
  *) exit 1 ;;
  esac
done
MOCK
  } >"$directory/stat"
  chmod +x "$directory/stat"
}

function use_mock() {
  local dialect="$1"
  mock_stat "$FIXTURE/$dialect/bin" "$dialect"
  export STAT_TRACE="$FIXTURE/stat.trace"
  : >"$STAT_TRACE"
  PATH="$FIXTURE/$dialect/bin:$ORIGINAL_PATH"
  export PATH
}

function trace_equals() {
  printf '%s' "$1" >"$FIXTURE/expected.trace"
  cmp -s "$FIXTURE/expected.trace" "$STAT_TRACE" || fail 'unexpected stat syntax probes'
}

function gnu_uses_one_read_each_time() {
  load_helpers
  use_mock gnu
  _private_file_is_regular_and_unlinked "$FILE"
  equal 600 "$(_portable_stat_mode "$FILE")"
  _permissions_metadata_stat "$FILE"
  equal 600 "$PERMISSIONS_STAT_MODE"
  trace_equals $'-c\n-c\n-c\n'
}

function bsd_choice_survives_mode_substitutions() {
  load_helpers
  use_mock bsd
  _private_file_is_regular_and_unlinked "$FILE"
  equal 600 "$(_portable_stat_mode "$FILE")"
  equal 600 "$(_portable_stat_mode "$FILE")"
  _permissions_metadata_stat "$FILE"
  equal 600 "$PERMISSIONS_STAT_MODE"
  trace_equals $'-c\n-f\n-f\n-f\n-f\n'
}

function metadata_is_fresh_after_choice() {
  load_helpers
  use_mock bsd
  _private_file_is_regular_and_unlinked "$FILE"
  export MOCK_MODE=6600
  equal 6600 "$(_portable_stat_mode "$FILE")"
  _permissions_metadata_stat "$FILE"
  equal 6600 "$PERMISSIONS_STAT_MODE" 'BSD full mode lost special bits'
  export MOCK_MODE=400
  equal 400 "$(_portable_stat_mode "$FILE")"
  _permissions_metadata_stat "$FILE"
  equal 400 "$PERMISSIONS_STAT_MODE" 'metadata was reused after a change'
  export MOCK_LINKS=2
  if _private_file_is_regular_and_unlinked "$FILE"; then fail 'fresh hard-link count ignored'; fi
  if _permissions_metadata_stat "$FILE"; then fail 'metadata helper ignored new hard link'; fi
}

function path_change_reselects() {
  load_helpers
  use_mock bsd
  _private_file_is_regular_and_unlinked "$FILE"
  mock_stat "$FIXTURE/gnu/bin" gnu
  PATH="$FIXTURE/gnu/bin:$ORIGINAL_PATH"
  _private_file_is_regular_and_unlinked "$FILE"
  trace_equals $'-c\n-f\n-c\n'
}

function relative_path_cwd_change_reselects() {
  load_helpers
  use_mock bsd
  mock_stat "$FIXTURE/gnu/bin" gnu
  cd "$FIXTURE/bsd"
  PATH="bin:$ORIGINAL_PATH"
  _private_file_is_regular_and_unlinked "$FILE"
  cd "$FIXTURE/gnu"
  _private_file_is_regular_and_unlinked "$FILE"
  trace_equals $'-c\n-f\n-c\n'
}

function replaced_tool_retries_other_dialect() {
  load_helpers
  use_mock bsd
  _private_file_is_regular_and_unlinked "$FILE"
  mock_stat "$FIXTURE/bsd/bin" gnu
  _private_file_is_regular_and_unlinked "$FILE"
  _private_file_is_regular_and_unlinked "$FILE"
  trace_equals $'-c\n-f\n-f\n-c\n-c\n'
}

function replaced_gnu_tool_retries_bsd_dialect() {
  load_helpers
  use_mock gnu
  _private_file_is_regular_and_unlinked "$FILE"
  mock_stat "$FIXTURE/gnu/bin" bsd
  _private_file_is_regular_and_unlinked "$FILE"
  _private_file_is_regular_and_unlinked "$FILE"
  trace_equals $'-c\n-c\n-f\n-f\n'
}

function function_mock_bypasses_choice() {
  load_helpers
  use_mock bsd
  _private_file_is_regular_and_unlinked "$FILE"
  function stat() {
    printf '%s\n' "${1:-}" >>"$STAT_TRACE"
    [ "${1:-}" = -c ] || return 1
    printf '640\n'
  }
  equal 640 "$(_portable_stat_mode "$FILE")"
  unset -f stat
  _private_file_is_regular_and_unlinked "$FILE"
  trace_equals $'-c\n-f\n-c\n-f\n'
}

function stat_failures_do_not_publish_or_trap() {
  load_helpers
  use_mock bsd
  trap 'printf "unexpected ERR trap\n" >>"$FIXTURE/err.trace"' ERR
  _private_file_is_regular_and_unlinked "$FILE"
  export MOCK_FAIL=true
  if _permissions_metadata_stat "$FILE"; then fail 'both failed stat calls accepted'; fi
  # A cached BSD failure may try GNU once, but must not retry BSD again.
  trace_equals $'-c\n-f\n-f\n-c\n'
  equal '' "$PERMISSIONS_STAT_RECORD" 'failed stat output escaped helper'
  if result="$(_portable_stat_mode "$FILE" || exit 1)"; then fail 'failed mode read accepted'; fi
  equal '' "$result" 'failed mode read published bytes'
  [ ! -e "$FIXTURE/err.trace" ] || fail 'handled syntax probe fired ERR trap'
  trap - ERR
}

function malformed_modes_remain_rejected() {
  load_helpers
  use_mock bsd
  _private_file_is_regular_and_unlinked "$FILE"
  local invalid=""
  for invalid in '' not-octal 104888 200000 10000000 '104600 extra'; do
    export MOCK_FULL_MODE="$invalid"
    if _portable_stat_mode "$FILE" >/dev/null; then fail 'malformed BSD mode accepted'; fi
    if _permissions_metadata_stat "$FILE"; then fail 'malformed BSD metadata accepted'; fi
  done
}

function actual_files_are_rechecked() {
  load_helpers
  chmod 600 "$FILE"
  _private_file_is_regular_and_unlinked "$FILE"
  equal 600 "$(_portable_stat_mode "$FILE")"
  chmod 400 "$FILE"
  equal 400 "$(_portable_stat_mode "$FILE")"
  _permissions_metadata_stat "$FILE"
  equal 400 "$PERMISSIONS_STAT_MODE"
  ln "$FILE" "$FIXTURE/hardlink"
  if _private_file_is_regular_and_unlinked "$FILE"; then fail 'real new hard link ignored'; fi
  if _permissions_metadata_stat "$FILE"; then fail 'real new hard link accepted by metadata'; fi
  rm "$FIXTURE/hardlink"
  mv "$FILE" "$FIXTURE/moved"
  ln -s "$FIXTURE/moved" "$FILE"
  if _private_file_is_regular_and_unlinked "$FILE"; then fail 'replacement symlink accepted'; fi
  if _permissions_metadata_stat "$FILE"; then fail 'replacement symlink accepted by metadata'; fi
}

function direct_metadata_sourcing() {
  # shellcheck source=../lib/permissions/metadata_transaction.sh
  source "$ROOT_DIR/lib/permissions/metadata_transaction.sh"
  use_mock bsd
  _permissions_metadata_stat "$FILE"
  _permissions_metadata_stat "$FILE"
  trace_equals $'-c\n-f\n-f\n'
}

function inherited_choice_is_discarded() {
  use_mock gnu
  export PERMISSIONS_STAT_CACHED_DIALECT=bsd PERMISSIONS_STAT_CACHED_PATH="$PATH" PERMISSIONS_STAT_CACHED_PWD="$PWD"
  load_helpers
  _private_file_is_regular_and_unlinked "$FILE"
  trace_equals $'-c\n'
}

# Isolate the private-file write pass from unrelated directory/global-settings
# work. Existing permission suites verify those security guards and mutations.
function capture_private_write_pass() {
  function _runtime_nginx_config_dir_mode() { printf 750; }
  function runtime_state_paths_guard() { :; }
  function _ensure_runtime_dir_mode() { :; }
  function _ensure_global_settings_file_permissions_if_exists() { :; }
  function _ensure_runtime_file_mode_if_exists() { :; }
  function _ensure_private_file_permissions_if_exists() {
    printf '%s\0' "$1" >>"$FIXTURE/actual.paths"
  }
  local BACKUP_DIR="" CAPTURE_DIR="" NGINX_CONFIG_DIR="" NGINX_HTTP_CONF_DIR="" NGINX_STREAM_CONF_DIR=""
  : >"$FIXTURE/actual.paths"
  ensure_runtime_state_permissions
}

function default_write_pass_is_unique() {
  load_helpers
  local CONFIG_DIR=/config LOG_DIR=/logs
  local INTERACTIVE_RECENT_FILE=/config/interactive_recent.csv INTERACTIVE_FAVORITES_FILE=/config/interactive_favorites.csv
  local LOG_FILE=/logs/docker_manager.log AUDIT_LOG_FILE=/logs/audit.log
  local BACKEND_DOCKER_OPTS_FILE=/config/backend_docker_opts.csv CAPTURE_TLS_STATE_FILE=/config/capture_tls_decrypt.state
  local -a PRIVATE_RUNTIME_FILE_PATHS=()
  _collect_private_runtime_file_paths
  equal 13 "${#PRIVATE_RUNTIME_FILE_PATHS[@]}" 'raw collector changed for permission classification'
  _is_private_runtime_file /config/backend_identity.csv || fail 'backend identity sidecar was not classified as private'
  capture_private_write_pass
  printf '%s\0' /config/interactive_recent.csv /config/interactive_favorites.csv /logs/docker_manager.log \
    /logs/audit.log /config/backend_docker_opts.csv /config/capture_tls_decrypt.state /config/backend_identity.csv /logs/audit.log.1 >"$FIXTURE/expected.paths"
  cmp -s "$FIXTURE/expected.paths" "$FIXTURE/actual.paths" || fail 'default private write pass repeated or reordered paths'
}

function custom_and_literal_paths_survive() {
  load_helpers
  local CONFIG_DIR=$'/config space\n' LOG_DIR='/logs *?[x]'
  # Both locals are consumed through the collector's dynamic scope.
  # shellcheck disable=SC2034
  local INTERACTIVE_RECENT_FILE=$'/custom\nrecent' INTERACTIVE_FAVORITES_FILE=$'/custom\nrecent'
  local LOG_FILE='/logs *?[x]//docker_manager.log' AUDIT_LOG_FILE='/custom audit'
  local BACKEND_DOCKER_OPTS_FILE='/custom options' CAPTURE_TLS_STATE_FILE='/custom capture'
  local -a PRIVATE_RUNTIME_FILE_PATHS=()
  _collect_private_runtime_file_paths
  equal 13 "${#PRIVATE_RUNTIME_FILE_PATHS[@]}" 'raw custom/default candidates must remain intact'
  _is_private_runtime_file "$CONFIG_DIR/backend_identity.csv" || fail 'literal backend identity path was not classified as private'
  equal "$INTERACTIVE_RECENT_FILE" "${PRIVATE_RUNTIME_FILE_PATHS[0]}"
  equal "$INTERACTIVE_RECENT_FILE" "${PRIVATE_RUNTIME_FILE_PATHS[1]}"
  capture_private_write_pass
  printf '%s\0' "$INTERACTIVE_RECENT_FILE" "$LOG_FILE" "$AUDIT_LOG_FILE" "$BACKEND_DOCKER_OPTS_FILE" "$CAPTURE_TLS_STATE_FILE" \
    "$CONFIG_DIR/interactive_recent.csv" "$CONFIG_DIR/interactive_favorites.csv" "$CONFIG_DIR/backend_identity.csv" \
    "$LOG_DIR/docker_manager.log" "$LOG_DIR/audit.log" "$LOG_DIR/audit.log.1" "$AUDIT_LOG_FILE.1" >"$FIXTURE/expected.paths"
  cmp -s "$FIXTURE/expected.paths" "$FIXTURE/actual.paths" || fail 'literal/custom/default paths changed'
  LOG_FILE=/later-log
  capture_private_write_pass
  printf '%s\0' "$INTERACTIVE_RECENT_FILE" "$LOG_FILE" "$AUDIT_LOG_FILE" "$BACKEND_DOCKER_OPTS_FILE" "$CAPTURE_TLS_STATE_FILE" \
    "$CONFIG_DIR/interactive_recent.csv" "$CONFIG_DIR/interactive_favorites.csv" "$CONFIG_DIR/backend_identity.csv" \
    "$LOG_DIR/docker_manager.log" "$LOG_DIR/audit.log" "$LOG_DIR/audit.log.1" "$AUDIT_LOG_FILE.1" >"$FIXTURE/expected.paths"
  cmp -s "$FIXTURE/expected.paths" "$FIXTURE/actual.paths" || fail 'paths cached across operations'
}

function empty_paths_support_nounset() {
  load_helpers
  unset CONFIG_DIR LOG_DIR INTERACTIVE_RECENT_FILE INTERACTIVE_FAVORITES_FILE LOG_FILE AUDIT_LOG_FILE BACKEND_DOCKER_OPTS_FILE CAPTURE_TLS_STATE_FILE
  local -a PRIVATE_RUNTIME_FILE_PATHS=()
  _collect_private_runtime_file_paths
  equal 6 "${#PRIVATE_RUNTIME_FILE_PATHS[@]}" 'empty raw collector changed'
  capture_private_write_pass
  [ ! -s "$FIXTURE/actual.paths" ] || fail 'empty private paths reached write pass'
  if _is_private_runtime_file "$FILE"; then fail 'unconfigured file classified as private'; fi
}

cases=(gnu_uses_one_read_each_time bsd_choice_survives_mode_substitutions metadata_is_fresh_after_choice
  path_change_reselects relative_path_cwd_change_reselects replaced_tool_retries_other_dialect
  replaced_gnu_tool_retries_bsd_dialect function_mock_bypasses_choice stat_failures_do_not_publish_or_trap malformed_modes_remain_rejected
  actual_files_are_rechecked direct_metadata_sourcing inherited_choice_is_discarded
  default_write_pass_is_unique custom_and_literal_paths_survive empty_paths_support_nounset)
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --case ] || fail 'expected --case <name>'
  selected_case=false
  for case_name in "${cases[@]}"; do [ "$case_name" != "$2" ] || selected_case=true; done
  [ "$selected_case" = true ] || fail 'unknown permission startup case'
  FILE="$FIXTURE/ordinary file"
  printf 'fixture\n' >"$FILE"
  "$2"
  exit 0
fi

for case_name in "${cases[@]}"; do
  case_log="$FIXTURE/$case_name.log"
  case_status=0
  "$BASH" "$0" --case "$case_name" >"$case_log" 2>&1 || case_status=$?
  if [ "$case_status" -ne 0 ] || [ -s "$case_log" ]; then
    cat "$case_log" >&2
    fail "Permission startup case failed: $case_name (status $case_status)"
  fi
  printf '[tests] permission-startup-overhead PASS: %s\n' "$case_name"
done
printf '[tests] Permission startup overhead tests passed (%s cases).\n' "${#cases[@]}"
