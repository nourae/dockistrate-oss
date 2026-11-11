#!/usr/bin/env bash
set -Eeuo pipefail

# These 21 cases replace the former Python CaptureDirectoryTests one for one.
# Fault injection wraps real shell operations in an isolated case subshell; no
# production test hook or alternate filesystem implementation is selected.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/capture/output_io.sh
source "$ROOT_DIR/lib/capture/output_io.sh"
# shellcheck source=../lib/capture/output_paths.sh
source "$ROOT_DIR/lib/capture/output_paths.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_capture_output.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
chmod 700 "$TEST_ROOT"
COMPLETED=false
CASE_LABEL=setup
CASE_COUNT=0
TEST_KERNEL="$(uname -s)"

function fail() { printf '[Error] %s: %s\n' "$CASE_LABEL" "$*" >&2; exit 1; }
function finish() {
  local status="$?"
  if [ "$COMPLETED" = true ] && [ "$status" -eq 0 ]; then
    rm -rf "$TEST_ROOT"
  else
    printf '[Diagnostics] Capture output fixture retained at %s\n' "$TEST_ROOT" >&2
    status=1
  fi
  exit "$status"
}
trap finish EXIT

function metadata() {
  if [ "$TEST_KERNEL" = Darwin ]; then
    # Floating-point m/c fields include native subsecond timestamps.
    stat -f '%d:%i:%u:%g:%Lp:%z:%.9Fm:%.9Fc' "$1"
  else
    stat -c '%d:%i:%u:%g:%a:%s:%y:%z' "$1"
  fi
}
function identity() {
  if [ "$TEST_KERNEL" = Darwin ]; then stat -f '%d:%i' "$1"; else stat -c '%d:%i' "$1"; fi
}
function mode() {
  if [ "$TEST_KERNEL" = Darwin ]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}
function snapshot_foreign() {
  metadata "$OUTSIDE"
  metadata "$OUTSIDE/sentinel.pcap"
  cat "$OUTSIDE/sentinel.pcap"
  (cd "$OUTSIDE" && LC_ALL=C find . -print | LC_ALL=C sort)
}
function setup_case() {
  BASE="$TEST_ROOT/$CASE_LABEL"
  CAPTURE_ROOT="$BASE/pcaps"
  TARGET="$CAPTURE_ROOT/nested"
  OUTSIDE="$BASE/outside"
  OUTPUT="$BASE/output"
  EVENTS="$BASE/events"
  mkdir -p "$CAPTURE_ROOT" "$OUTSIDE"
  chmod 755 "$CAPTURE_ROOT" "$OUTSIDE"
  printf '%s\n' 'external disposable evidence' >"$OUTSIDE/sentinel.pcap"
  chmod 644 "$OUTSIDE/sentinel.pcap"
  : >"$OUTPUT"
  : >"$EVENTS"
  snapshot_foreign >"$BASE/foreign.before"
}
function case_finished() {
  local status="$?"
  snapshot_foreign >"$BASE/foreign.after" || status=1
  if ! cmp -s "$BASE/foreign.before" "$BASE/foreign.after"; then
    printf '[Error] %s: foreign inode, metadata, bytes or entries changed\n' "$CASE_LABEL" >&2
    status=1
  fi
  if [ "$status" -ne 0 ]; then cat "$OUTPUT" >&2; fi
  # Bash 3 can report zero for an EXIT-trapped subshell that explicitly exits
  # nonzero. The parent checks this receipt as well as the process status.
  printf '%s\n' "$status" >"$BASE/case.status"
  exit "$status"
}
function rejected() {
  local status=0
  "$@" >"$OUTPUT" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "unexpected success: $*"
}
function prepare() {
  PREPARED_PATH="" PREPARED_ID=""
  _capture_output_prepare PREPARED_PATH PREPARED_ID "$CAPTURE_ROOT" "${1:-$TARGET}" || fail 'prepare failed'
}
function reserved_rejected() {
  rejected "$@"
  grep -Fq 'reserved for TLS session keys' "$OUTPUT" || fail 'reserved inode was not identified'
}
function install_alias() {
  # Model an OS name-equivalence lookup at the real directory-entry boundary.
  # The returned inode is real, and all mutation/guard functions stay real.
  eval "$(declare -f _secure_fs_enter_directory | sed '1s/_secure_fs_enter_directory/_original_enter_directory/')"
  function _secure_fs_enter_directory() {
    local entry="$1" policy="${2:-existing}"
    if [ "$entry" = "$ALIAS" ]; then
      printf 'alias:%s\n' "$policy" >>"$EVENTS"
      entry=tls-keys
    fi
    [ "$entry" != new-child ] || printf '%s\n' descendant >>"$EVENTS"
    _original_enter_directory "$entry" "$policy"
  }
}

function test_missing_nested_directories_are_private_and_verified() {
  TARGET="$TARGET/new/leaf"
  _capture_output_preflight "$CAPTURE_ROOT" "$TARGET" || fail 'missing target preflight failed'
  [ ! -e "$TARGET" ] || fail 'preflight created target'
  prepare
  [ "$PREPARED_PATH" = "$TARGET" ] || fail 'output layout changed'
  local directory
  for directory in "$CAPTURE_ROOT" "$CAPTURE_ROOT/nested" "$TARGET/.." "$TARGET"; do
    [ "$(mode "$directory")" = 700 ] || fail 'new directory is not private'
  done
  _capture_output_verify "$CAPTURE_ROOT" "$TARGET" "$PREPARED_ID" || fail 'prepared target did not verify'
}
function test_missing_root_preflight_is_read_only() {
  rmdir "$CAPTURE_ROOT"
  _capture_output_preflight "$CAPTURE_ROOT" "$TARGET" || fail 'missing root preflight failed'
  [ ! -e "$CAPTURE_ROOT" ] || fail 'preflight created root'
  prepare
  [ -d "$TARGET" ] || fail 'prepare did not create target'
}
function test_existing_contents_are_preserved() {
  mkdir "$TARGET"
  printf '%s\n' 'previous capture' >"$TARGET/previous.pcap"
  chmod 640 "$TARGET/previous.pcap"
  metadata "$TARGET/previous.pcap" >"$BASE/existing.before"
  prepare
  metadata "$TARGET/previous.pcap" >"$BASE/existing.after"
  cmp -s "$BASE/existing.before" "$BASE/existing.after" || fail 'existing capture metadata changed'
  [ "$(cat "$TARGET/previous.pcap")" = 'previous capture' ] || fail 'existing capture bytes changed'
}
function test_default_output_is_capture_root() {
  prepare "$CAPTURE_ROOT"
  [ "$PREPARED_PATH" = "$CAPTURE_ROOT" ] || fail 'default output changed'
  local expected
  expected="$(identity "$CAPTURE_ROOT")"
  [ "$PREPARED_ID" = "$expected:$expected" ] || fail 'default identity is not root identity'
}
function test_outside_sibling_and_reserved_subtree_are_rejected() {
  local path
  for path in "$OUTSIDE" "$BASE/pcaps-other" "$CAPTURE_ROOT/tls-keys" \
    "$CAPTURE_ROOT/tls-keys/nested" "$CAPTURE_ROOT/a/../tls-keys" \
    "$CAPTURE_ROOT/TLS-KEYS" "$CAPTURE_ROOT/Tls-Keys/child"; do
    rejected _capture_output_preflight "$CAPTURE_ROOT" "$path"
  done
  _capture_output_preflight "$CAPTURE_ROOT" "$CAPTURE_ROOT/tls-keys-other" || fail 'unrelated sibling rejected'
}
function test_filesystem_alias_of_reserved_directory_is_rejected_in_every_phase() {
  local reserved="$CAPTURE_ROOT/tls-keys" operation suffix expected
  ALIAS=$'tls-\342\200\215keys'
  mkdir "$reserved"
  chmod 755 "$reserved"
  printf '%s\n' 'disposable existing key-log evidence' >"$reserved/session.log"
  metadata "$reserved" >"$BASE/reserved.before"
  expected="$(identity "$CAPTURE_ROOT"):$(identity "$reserved")"
  install_alias
  for operation in preflight prepare verify; do
    for suffix in '' /new-child; do
      if [ "$operation" = verify ]; then
        reserved_rejected _capture_output_run "$operation" "$CAPTURE_ROOT" "$CAPTURE_ROOT/$ALIAS$suffix" "$expected"
      else
        reserved_rejected _capture_output_run "$operation" "$CAPTURE_ROOT" "$CAPTURE_ROOT/$ALIAS$suffix"
      fi
    done
  done
  ! grep -q '^descendant$' "$EVENTS" || fail 'reserved descendant was entered'
  metadata "$reserved" >"$BASE/reserved.after"
  cmp -s "$BASE/reserved.before" "$BASE/reserved.after" || fail 'reserved inode metadata changed'
  [ "$(find "$reserved" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || fail 'reserved entries changed'
  [ "$(cat "$reserved/session.log")" = 'disposable existing key-log evidence' ] || fail 'key-log bytes changed'
}
function test_new_filesystem_alias_is_rejected_before_descendant_creation() {
  ALIAS=$'tls-\342\200\215keys'
  install_alias
  _capture_output_preflight "$CAPTURE_ROOT" "$CAPTURE_ROOT/$ALIAS/new-child" || fail 'new alias preflight failed'
  [ ! -e "$CAPTURE_ROOT/tls-keys" ] || fail 'preflight created new alias'
  reserved_rejected _capture_output_run prepare "$CAPTURE_ROOT" "$CAPTURE_ROOT/$ALIAS/new-child"
  [ -d "$CAPTURE_ROOT/tls-keys" ] || fail 'new alias model was not exercised'
  [ "$(grep -c '^alias:create$' "$EVENTS")" = 1 ] || fail 'new alias was not created exactly once'
  [ -z "$(find "$CAPTURE_ROOT/tls-keys" -mindepth 1 -print)" ] || fail 'reserved descendant was created'
  ! grep -q '^descendant$' "$EVENTS" || fail 'reserved descendant was entered'
}
function test_unreadable_reserved_identity_fails_closed() {
  mkdir "$TARGET"
  chmod 755 "$TARGET"
  function _capture_output_reserved_identity() { printf '%s\n' inspected >>"$EVENTS"; return 1; }
  rejected _capture_output_preflight "$CAPTURE_ROOT" "$TARGET"
  rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET"
  [ "$(wc -l <"$EVENTS" | tr -d ' ')" = 2 ] || fail 'reserved identity failure was not exercised'
  [ "$(mode "$TARGET")" = "$(mode "$OUTSIDE")" ] || fail 'target changed before reserved inspection'
}
function test_actual_filesystem_unicode_aliases_use_identity_not_a_text_policy() {
  local reserved="$CAPTURE_ROOT/tls-keys" spelling candidate reserved_id
  mkdir "$reserved"
  chmod 755 "$reserved"
  reserved_id="$(identity "$reserved")"
  for spelling in $'tl\342\200\214s-keys' $'tl\305\277-keys'; do
    candidate="$CAPTURE_ROOT/$spelling"
    mkdir "$candidate" 2>/dev/null || [ -d "$candidate" ] || fail 'cannot establish native alias fixture'
    if [ "$(identity "$candidate")" = "$reserved_id" ]; then
      reserved_rejected _capture_output_preflight "$CAPTURE_ROOT" "$candidate"
      reserved_rejected _capture_output_run prepare "$CAPTURE_ROOT" "$candidate"
    else
      _capture_output_preflight "$CAPTURE_ROOT" "$candidate" || fail 'distinct Unicode name rejected'
      prepare "$candidate"
      [ "$PREPARED_PATH" = "$candidate" ] || fail 'Unicode name changed'
      _capture_output_verify "$CAPTURE_ROOT" "$candidate" "$PREPARED_ID" || fail 'Unicode directory verification failed'
    fi
  done
  [ "$(mode "$reserved")" = 755 ] || fail 'reserved native alias mode changed'
  [ -z "$(find "$reserved" -mindepth 1 -print)" ] || fail 'reserved native alias gained entries'
}
function test_reserved_rejection_closes_all_open_directory_descriptors() {
  local expected operation cwd_before="$PWD" fd8_before fd9_before
  mkdir "$CAPTURE_ROOT/tls-keys"
  ALIAS=filesystem-alias
  install_alias
  expected="$(identity "$CAPTURE_ROOT"):$(identity "$CAPTURE_ROOT/tls-keys")"
  printf '%s\n' 'caller descriptor eight' >"$BASE/fd8"
  printf '%s\n' 'caller descriptor nine' >"$BASE/fd9"
  exec 8<"$BASE/fd8" 9<"$BASE/fd9"
  # The worker uses cwd instead of an accumulating descriptor walk. Parent
  # cwd and inherited caller descriptors must survive every rejected worker.
  for operation in preflight prepare verify; do
    if [ "$operation" = verify ]; then
      reserved_rejected _capture_output_run "$operation" "$CAPTURE_ROOT" "$CAPTURE_ROOT/$ALIAS" "$expected"
    else
      reserved_rejected _capture_output_run "$operation" "$CAPTURE_ROOT" "$CAPTURE_ROOT/$ALIAS"
    fi
    [ "$PWD" = "$cwd_before" ] || fail 'worker leaked its cwd into caller'
    : <&8 || fail 'worker closed caller descriptor eight'
    : <&9 || fail 'worker closed caller descriptor nine'
  done
  IFS= read -r fd8_before <&8 || fail 'caller descriptor eight was consumed'
  IFS= read -r fd9_before <&9 || fail 'caller descriptor nine was consumed'
  [ "$fd8_before" = 'caller descriptor eight' ] && [ "$fd9_before" = 'caller descriptor nine' ] || fail 'caller descriptors changed'
  exec 8<&- 9<&-
}
function test_filesystem_root_and_relative_inputs_are_rejected() {
  rejected _capture_output_preflight / "$TARGET"
  rejected _capture_output_preflight relative "$TARGET"
  rejected _capture_output_preflight "$CAPTURE_ROOT" relative
  rejected _capture_output_run preflight "$CAPTURE_ROOT"
  rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET" unexpected
  # NUL cannot occur in a Bash variable or OS argv. The former direct Python
  # NUL-string subcase therefore has no shell-callable input counterpart.
}
function test_dot_segments_and_repeated_separators_keep_layout() {
  local selected="$CAPTURE_ROOT//old/.././nested/"
  prepare "$selected"
  [ "$PREPARED_PATH" = "$TARGET" ] || fail 'normalized layout changed'
  [ ! -e "$CAPTURE_ROOT/old" ] || fail 'normalized-away directory was created'
  _capture_output_verify "$CAPTURE_ROOT" "$selected" "$PREPARED_ID" || fail 'normalized target verification failed'
}
function test_symlink_directory_and_dangling_link_are_rejected() {
  local destination
  for destination in "$OUTSIDE" "$BASE/missing"; do
    ln -s "$destination" "$TARGET"
    rejected _capture_output_preflight "$CAPTURE_ROOT" "$TARGET/new"
    rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET"
    rm "$TARGET"
  done
  [ ! -e "$BASE/missing" ] || fail 'dangling link destination was created'
}
function test_symlink_capture_root_is_rejected() {
  rmdir "$CAPTURE_ROOT"
  ln -s "$OUTSIDE" "$CAPTURE_ROOT"
  rejected _capture_output_preflight "$CAPTURE_ROOT" "$TARGET"
  rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET"
}
function test_swap_after_preflight_is_rejected_before_external_metadata() {
  mkdir "$TARGET"
  _capture_output_preflight "$CAPTURE_ROOT" "$TARGET" || fail 'initial preflight failed'
  mv "$TARGET" "$CAPTURE_ROOT/retired"
  ln -s "$OUTSIDE" "$TARGET"
  rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET"
}
function test_swap_before_relative_open_cannot_redirect_mkdir_or_chmod() {
  mkdir "$TARGET"
  eval "$(declare -f _secure_fs_stat_path | sed '1s/_secure_fs_stat_path/_original_stat_path/')"
  function _secure_fs_stat_path() {
    local status=0
    _original_stat_path "$@" || status=$?
    # Swap after the successful lstat but before the real relative cd. This
    # exercises the shell-specific check/use boundary, not just a static link.
    if [ "$1" = ./nested ] && [ "$status" -eq 0 ] && [ ! -s "$EVENTS" ]; then
      printf '%s\n' swapped >>"$EVENTS"
      mv "$TARGET" "$CAPTURE_ROOT/retired"
      ln -s "$OUTSIDE" "$TARGET"
    fi
    return "$status"
  }
  rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET/new"
  [ "$(cat "$EVENTS")" = swapped ] || fail 'relative-entry race not exercised'
  [ ! -e "$CAPTURE_ROOT/retired/new" ] || fail 'failed entry created descendants'
}
function test_swap_after_open_cannot_redirect_chmod_and_fails_verification() {
  mkdir "$TARGET"
  chmod 755 "$TARGET"
  local selected_id
  selected_id="$(identity "$TARGET")"
  eval "$(declare -f _secure_fs_chmod_cwd | sed '1s/_secure_fs_chmod_cwd/_original_chmod_cwd/')"
  function _secure_fs_chmod_cwd() {
    if [ "$(identity .)" = "$selected_id" ] && [ ! -s "$EVENTS" ]; then
      printf '%s\n' swapped >>"$EVENTS"
      mv "$TARGET" "$CAPTURE_ROOT/retired"
      ln -s "$OUTSIDE" "$TARGET"
    fi
    _original_chmod_cwd "$@"
  }
  rejected _capture_output_run prepare "$CAPTURE_ROOT" "$TARGET"
  [ "$(cat "$EVENTS")" = swapped ] || fail 'post-entry race not exercised'
  [ "$(identity "$CAPTURE_ROOT/retired")" = "$selected_id" ] || fail 'selected inode changed'
  [ "$(mode "$CAPTURE_ROOT/retired")" = 700 ] || fail 'chmod did not apply to pinned original directory'
}
function test_replacement_root_or_leaf_identity_is_rejected() {
  prepare
  mv "$TARGET" "$CAPTURE_ROOT/retired"
  mkdir "$TARGET"
  rejected _capture_output_verify "$CAPTURE_ROOT" "$PREPARED_PATH" "$PREPARED_ID"
  mv "$CAPTURE_ROOT" "$BASE/retired-root"
  mkdir -p "$TARGET"
  rejected _capture_output_verify "$CAPTURE_ROOT" "$PREPARED_PATH" "$PREPARED_ID"
}
function test_invalid_identity_never_changes_directories() {
  local invalid
  prepare
  metadata "$CAPTURE_ROOT" >"$BASE/root.before"
  metadata "$TARGET" >"$BASE/target.before"
  for invalid in '' 1:2:3 1:2:3:4:5 1:2:-3:4 $'1:2:\331\243:4'; do
    rejected _capture_output_verify "$CAPTURE_ROOT" "$PREPARED_PATH" "$invalid"
  done
  metadata "$CAPTURE_ROOT" >"$BASE/root.after"
  metadata "$TARGET" >"$BASE/target.after"
  cmp -s "$BASE/root.before" "$BASE/root.after" || fail 'invalid identity changed root'
  cmp -s "$BASE/target.before" "$BASE/target.after" || fail 'invalid identity changed target'
}
function test_only_fixed_macos_system_aliases_are_normalized() {
  function readlink() { printf '%s\n' "$READLINK_VALUE"; }
  READLINK_VALUE=private/var
  _capture_output_normalize /var/folders/capture || fail 'system alias normalization failed'
  [ "$CAPTURE_OUTPUT_NORMALIZED_PATH" = /private/var/folders/capture ] || fail 'documented alias not normalized'
  READLINK_VALUE=/attacker
  _capture_output_normalize /var/folders/capture || fail 'literal normalization failed'
  [ "$CAPTURE_OUTPUT_NORMALIZED_PATH" = /var/folders/capture ] || fail 'arbitrary link normalized'
}
function test_shell_protocol_preserves_newlines_and_propagates_failure() {
  TARGET="$CAPTURE_ROOT/"$'nested space\n/leaf\n'
  local actual="" selected_identity="" status=0
  _capture_output_preflight "$CAPTURE_ROOT" "$TARGET" || fail 'newline preflight failed'
  _capture_output_prepare actual selected_identity "$CAPTURE_ROOT" "$TARGET" || fail 'newline preparation failed'
  [ "$actual" = "$TARGET" ] || fail 'newline path did not survive shell assignment'
  _capture_output_verify "$CAPTURE_ROOT" "$actual" "$selected_identity" || fail 'newline path verification failed'
  [ "$selected_identity" = "$(identity "$CAPTURE_ROOT"):$(identity "$TARGET")" ] || fail 'newline identity protocol changed'
  actual=unchanged selected_identity=unchanged
  _capture_output_prepare actual selected_identity "$CAPTURE_ROOT" "$OUTSIDE" >"$BASE/stdout" 2>"$OUTPUT" || status=$?
  [ "$status" -ne 0 ] || fail 'unsafe wrapper preparation succeeded'
  [ ! -s "$BASE/stdout" ] || fail 'failed preparation emitted a success protocol'
  [ "$actual:$selected_identity" = unchanged:unchanged ] || fail 'failed preparation assigned result variables'
}

CASES=(
  missing_nested_directories_are_private_and_verified
  missing_root_preflight_is_read_only
  existing_contents_are_preserved
  default_output_is_capture_root
  outside_sibling_and_reserved_subtree_are_rejected
  filesystem_alias_of_reserved_directory_is_rejected_in_every_phase
  new_filesystem_alias_is_rejected_before_descendant_creation
  unreadable_reserved_identity_fails_closed
  actual_filesystem_unicode_aliases_use_identity_not_a_text_policy
  reserved_rejection_closes_all_open_directory_descriptors
  filesystem_root_and_relative_inputs_are_rejected
  dot_segments_and_repeated_separators_keep_layout
  symlink_directory_and_dangling_link_are_rejected
  symlink_capture_root_is_rejected
  swap_after_preflight_is_rejected_before_external_metadata
  swap_before_relative_open_cannot_redirect_mkdir_or_chmod
  swap_after_open_cannot_redirect_chmod_and_fails_verification
  replacement_root_or_leaf_identity_is_rejected
  invalid_identity_never_changes_directories
  only_fixed_macos_system_aliases_are_normalized
  shell_protocol_preserves_newlines_and_propagates_failure
)
for CASE_LABEL in "${CASES[@]}"; do
  (
    trap - EXIT
    setup_case
    trap case_finished EXIT
    "test_$CASE_LABEL"
  )
  [ "$(cat "$TEST_ROOT/$CASE_LABEL/case.status")" = 0 ] || fail 'case failed (see retained diagnostics)'
  CASE_COUNT=$((CASE_COUNT + 1))
  printf '[PASS] %s\n' "$CASE_LABEL"
done
printf 'Capture output filesystem safety: %s cases passed.\n' "$CASE_COUNT"
COMPLETED=true
