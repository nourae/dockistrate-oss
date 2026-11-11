#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A separate frozen source export permits a negative control without editing it.
SOURCE_ROOT="${LITERAL_PATH_SOURCE_ROOT:-$ROOT_DIR}"

# These files only declare functions. All paths and operations below belong to
# the temporary fixture; application bootstrap and Docker are never invoked.
# shellcheck source=../lib/runtime_paths.sh
source "$SOURCE_ROOT/lib/runtime_paths.sh"
# shellcheck source=../lib/utils/fs.sh
source "$SOURCE_ROOT/lib/utils/fs.sh"
# shellcheck source=../lib/utils/validators.sh
source "$SOURCE_ROOT/lib/utils/validators.sh"
# shellcheck source=../lib/capture/common.sh
source "$SOURCE_ROOT/lib/capture/common.sh"
# shellcheck source=../lib/capture/filter_helpers.sh
source "$SOURCE_ROOT/lib/capture/filter_helpers.sh"
# shellcheck source=../lib/capture/start_capture.sh
source "$SOURCE_ROOT/lib/capture/start_capture.sh"

function fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function expect_bytes() {
  local expected="$1"
  shift
  printf '%s' "$expected" >"$CASE_DIR/expected"
  "$@" >"$CASE_DIR/actual" || fail "helper failed: $*"
  cmp -s "$CASE_DIR/expected" "$CASE_DIR/actual" ||
    fail "helper changed literal path bytes: ${1:-unknown}"
}

function expect_assignment() {
  local expected="$1" helper="$2" literal_output=""
  shift 2
  "$helper" literal_output "$@" || fail "assignment helper failed: $helper"
  printf '%s' "$expected" >"$CASE_DIR/expected"
  printf '%s' "$literal_output" >"$CASE_DIR/actual"
  cmp -s "$CASE_DIR/expected" "$CASE_DIR/actual" ||
    fail "assignment helper changed literal path bytes: $helper"
}

function expect_rejected() {
  if "$@" >"$CASE_DIR/rejected.stdout" 2>"$CASE_DIR/rejected.stderr"; then
    fail "unsafe or invalid request succeeded: ${1:-unknown}"
  fi
}

function lexical_bytes() {
  local name="" path=""
  for name in sample $'sample\n' $'sample\n\n' $'first\nsecond' 'with spaces' '-option-like'; do
    path="$CASE_DIR/$name"
    expect_bytes "$path" _runtime_path_strip_trailing_slashes "$path"
    expect_bytes "$path" _runtime_path_to_absolute_lexical "$path"
    expect_bytes "$path" _runtime_path_to_absolute_lexical "$path///"
  done
}

function relative_lexical_bytes() {
  cd "$CASE_DIR"
  expect_bytes "$CASE_DIR/"$'sample\n' _runtime_path_to_absolute_lexical $'sample\n'
  expect_bytes "$CASE_DIR/"$'sample\n' _runtime_path_to_absolute_lexical $'sample\n///'
}

function declared_suffix_bytes() {
  local path="$STATE_DIR/"$'first\nsecond\n' suffix=$'/first\nsecond\n'
  mkdir -p "$path"
  expect_bytes "$suffix" _runtime_state_declared_suffix "$path"
  expect_assignment "$suffix" _runtime_state_declared_suffix_assign "$path"
  expect_assignment "$suffix" _runtime_state_declared_suffix_assign "$path///"
}

function physical_paths() {
  local parent="$CASE_DIR/"$'parent\n' path=""
  mkdir -p "$parent"
  path="$parent/"$'first\nsecond\n\n'
  mkdir "$path"
  expect_bytes "$path" _realpath_portable "$path"
  expect_bytes "$path" _realpath_portable "$path///"
}

function physical_fallback() {
  function realpath() { return 1; }
  local original_pwd="$PWD" original_ifs="$IFS"
  physical_paths
  [ "$PWD" = "$original_pwd" ] || fail 'fallback changed caller PWD'
  [ "$IFS" = "$original_ifs" ] || fail 'fallback changed caller IFS'
}

function fallback_link_fixture() {
  LINK_PARENT="$CASE_DIR/"$'parent\n'
  LINK_TARGET_NAME=$'target\n\n'
  LINK_TARGET="$LINK_PARENT/$LINK_TARGET_NAME"
  LINK_PATH="$LINK_PARENT/-alias"
  mkdir -p "$LINK_TARGET"
  ln -s "$LINK_TARGET_NAME" "$LINK_PATH"
  function realpath() { return 1; }
}

function fallback_native_readlink() {
  fallback_link_fixture
  expect_bytes "$LINK_TARGET" _realpath_portable "$LINK_PATH"
}

function fallback_readlink_contract() {
  fallback_link_fixture
  function readlink() {
    local no_newline=false
    if [ "${1:-}" = -n ]; then
      no_newline=true
      shift
    fi
    if [ "${1:-}" = -- ]; then
      [ "$READLINK_FLAVOR" = gnu ] || return 2
      shift
    fi
    [ "$#" -eq 1 ] || return 2
    case "$1" in
    -*) return 2 ;;
    ./-alias | "$LINK_PATH") ;;
    *) return 1 ;;
    esac
    printf '%s' "$LINK_TARGET_NAME"
    if ! $no_newline; then
      # BSD readlink can omit its default delimiter if the target already ends
      # in LF. Both supported flavors emit the exact target bytes with -n.
      case "$READLINK_FLAVOR:$LINK_TARGET_NAME" in
      bsd:*$'\n') ;;
      *) printf '\n' ;;
      esac
    fi
  }
  expect_bytes "$LINK_TARGET" _realpath_portable "$LINK_PATH"
}

function fallback_gnu_readlink() {
  READLINK_FLAVOR=gnu
  fallback_readlink_contract
}

function fallback_bsd_readlink() {
  READLINK_FLAVOR=bsd
  fallback_readlink_contract
}

function failed_readlink_keeps_traps() {
  fallback_link_fixture
  function readlink() { printf 'untrusted-partial-result'; return 7; }
  : >"$CASE_DIR/traps"
  (
    trap 'printf "ERR\n" >>"$CASE_DIR/traps"' ERR
    trap 'printf "EXIT\n" >>"$CASE_DIR/traps"' EXIT
    if _realpath_portable "$LINK_PATH" >"$CASE_DIR/failed-result" 2>"$CASE_DIR/failed-error"; then
      fail 'readlink failure became a successful path'
    fi
    printf 'AFTER\n' >>"$CASE_DIR/traps"
  )
  printf 'AFTER\nEXIT\n' >"$CASE_DIR/expected-traps"
  cmp -s "$CASE_DIR/expected-traps" "$CASE_DIR/traps" ||
    fail 'expected utility failure triggered caller ERR or lost EXIT trap'
  [ ! -s "$CASE_DIR/failed-result" ] || fail 'failed resolution published partial bytes'
}

function missing_path_bytes() {
  local parent="$STATE_DIR/"$'parent\n' missing=""
  mkdir -p "$parent"
  missing="$parent/"$'missing\npart/leaf\n'
  expect_bytes "$missing" _runtime_path_resolve_allow_missing "$missing"
  [ ! -e "$missing" ] || fail 'path resolution created the missing target'
}

function guard_rejects_literal_link() {
  local literal="$STATE_DIR/"$'sample\n'
  mkdir -p "$STATE_DIR/sample" "$STATE_DIR/target"
  ln -s "$STATE_DIR/target" "$literal"
  expect_rejected runtime_state_path_guard "$literal"
  expect_rejected runtime_state_path_guard_if_declared "$literal"
  expect_rejected runtime_state_path_guard "$literal///"
  [ -L "$literal" ] && [ -d "$STATE_DIR/sample" ] || fail 'guard mutated fixture'
}

function guard_accepts_literal_directory() {
  local literal="$STATE_DIR/"$'sample\n'
  mkdir -p "$literal" "$STATE_DIR/target"
  ln -s "$STATE_DIR/target" "$STATE_DIR/sample"
  runtime_state_path_guard "$literal" || fail 'safe LF directory confused with sibling link'
  runtime_state_path_guard_if_declared "$literal" || fail 'declared guard lost LF identity'
}

function guard_rechecks_after_replacement() {
  local literal="$STATE_DIR/"$'sample\n'
  mkdir -p "$literal" "$STATE_DIR/sample" "$STATE_DIR/target"
  runtime_state_path_guard "$literal" || fail 'initial safe path rejected'
  rmdir "$literal"
  ln -s "$STATE_DIR/target" "$literal"
  expect_rejected runtime_state_path_guard "$literal"
  expect_rejected runtime_state_path_guard_if_declared "$literal"
}

function guard_missing_and_containment() {
  runtime_state_path_guard "$STATE_DIR/"$'missing\n/leaf\n' ||
    fail 'safe missing in-root path rejected'
  expect_rejected runtime_state_path_guard "$CASE_DIR/sibling"
  expect_rejected runtime_state_path_guard "$STATE_DIR/../sibling"
}

function state_root_ends_in_newline() {
  STATE_DIR="$CASE_DIR/"$'state\n'
  local literal="$STATE_DIR/"$'leaf\n'
  mkdir -p "$literal"
  # The ordinary sibling state directory was created by the case harness.
  [ -d "$CASE_DIR/state" ] || fail 'missing ordinary state sibling control'
  expect_bytes $'/leaf\n' _runtime_state_declared_suffix "$literal"
  expect_assignment $'/leaf\n' _runtime_state_declared_suffix_assign "$literal"
  runtime_state_path_guard "$literal" || fail 'literal LF state root was changed'
  runtime_state_path_guard_if_declared "$literal" || fail 'LF-root declared path rejected'
  rmdir "$literal"
  ln -s "$CASE_DIR/state" "$literal"
  expect_rejected runtime_state_path_guard "$literal"
  expect_rejected runtime_state_path_guard_if_declared "$literal"
}

function delete_directory_bytes() {
  local parent="$CASE_DIR/"$'parent\n' selected="" sibling=""
  mkdir -p "$parent"
  selected="$parent/"$'sample\n'
  sibling="$parent/sample"
  mkdir "$selected" "$sibling"
  printf 'selected\n' >"$selected/marker"
  printf 'sibling\n' >"$sibling/marker"
  safe_rm_rf "$selected///" "$parent" || fail 'literal directory delete failed'
  [ ! -e "$selected" ] || fail 'requested LF directory survived deletion'
  [ -f "$sibling/marker" ] || fail 'unrequested sibling directory was deleted'
}

function delete_file_bytes() {
  local parent="$CASE_DIR/"$'parent\n' selected="" sibling=""
  mkdir -p "$parent"
  selected="$parent/"$'sample\n\n'
  sibling="$parent/sample"
  printf 'selected\n' >"$selected"
  printf 'sibling\n' >"$sibling"
  safe_rm_f "$selected" "$parent" || fail 'literal file delete failed'
  [ ! -e "$selected" ] || fail 'requested LF file survived deletion'
  [ -f "$sibling" ] || fail 'unrequested sibling file was deleted'
}

function delete_missing_and_boundary() {
  local selected="$STATE_DIR/"$'missing\n'
  printf 'keep\n' >"$STATE_DIR/missing"
  safe_rm_f "$selected" "$STATE_DIR" || fail 'missing target should be a no-op'
  safe_rm_rf "$selected" "$STATE_DIR" || fail 'missing directory should be a no-op'
  [ -f "$STATE_DIR/missing" ] || fail 'missing LF request deleted ordinary sibling'
  mkdir "$CASE_DIR/sibling"
  expect_rejected safe_rm_rf "$CASE_DIR/sibling" "$STATE_DIR"
  [ -d "$CASE_DIR/sibling" ] || fail 'boundary rejection deleted sibling'
  expect_rejected safe_rm_rf / "$STATE_DIR"
  expect_rejected safe_rm_f '' "$STATE_DIR"
}

function delete_final_link() {
  local target="$STATE_DIR/target" link="$STATE_DIR/"$'alias\n'
  mkdir "$target"
  printf 'keep\n' >"$target/marker"
  ln -s "$target" "$link"
  safe_rm_rf "$link" "$STATE_DIR" || fail 'final symlink unlink failed'
  [ ! -L "$link" ] && [ -f "$target/marker" ] || fail 'exact directory link was not removed while preserving its target'
  ln -s "$target/marker" "$link"
  safe_rm_f "$link" "$STATE_DIR" || fail 'final file symlink unlink failed'
  [ ! -L "$link" ] && [ -f "$target/marker" ] || fail 'exact file link was not removed while preserving its target'
}

function delete_spaces_options_embedded() {
  local name="" selected=""
  for name in 'with spaces' '-option-like' $'first\nsecond'; do
    selected="$STATE_DIR/$name"
    mkdir "$selected"
    safe_rm_rf "$selected" "$STATE_DIR" || fail 'literal special-name deletion failed'
    [ ! -e "$selected" ] || fail 'special-name directory survived'
  done
}

function capture_resolver_bytes() {
  local parent="$CAPTURE_DIR/"$'parent\n' path="" name=""
  mkdir -p "$parent"
  for name in $'sample\n' $'sample\n\n' $'first\nsecond' 'with spaces' '-option-like'; do
    path="$parent/$name"
    mkdir "$path"
    expect_assignment "$path" _capture_collapse_absolute_path "$path"
    expect_assignment "$path" _capture_resolve_existing_path "$path"
    expect_assignment "$path" _capture_resolve_output_path "$path///"
  done
}

function capture_missing_bytes() {
  local parent="$CAPTURE_DIR/"$'parent\n' path=""
  mkdir -p "$parent"
  path="$parent/"$'missing\npart/leaf\n'
  expect_assignment "$path" _capture_resolve_output_path "$path"
  [ ! -e "$path" ] || fail 'capture resolver created a missing path'
}

function capture_missing_duplicate_separators() {
  mkdir -p "$CAPTURE_DIR"
  expect_assignment "$CAPTURE_DIR/new/deep" _capture_resolve_output_path "$CAPTURE_DIR/new//deep"
  expect_assignment "$CAPTURE_DIR/new/deep" _capture_resolve_output_path "$CAPTURE_DIR/new///deep///"
  [ ! -e "$CAPTURE_DIR/new" ] || fail 'capture resolver created a missing ordinary path'
}

function capture_missing_duplicate_separators_with_newlines() {
  local parent="$CAPTURE_DIR/"$'parent\n' expected="" requested=""
  mkdir -p "$parent"
  expected="$parent/"$'new\n/deep\n'
  requested="$parent/"$'new\n'"//"$'deep\n'
  expect_assignment "$expected" _capture_resolve_output_path "$requested"
  expect_assignment "$expected" _capture_resolve_output_path "$requested///"
  [ ! -e "$parent/"$'new\n' ] || fail 'capture resolver created a missing LF path'
}

function mock_capture_runtime() {
  CAPTURE_IMAGE=capture:test
  NGINX_CONTAINER_NAME=nginx-proxy
  INTERACTIVE=false
  function require_managed_nginx_container() { return 0; }
  function container_running() { return 0; }
  function remove_container_and_anonymous_volumes() { return 0; }
  function _capture_tls_launch_begin() { fail 'unexpected TLS decrypt request'; }
  function _capture_tls_launch_abort() { fail 'unexpected capture abort'; }
  function _capture_tls_launch_finish() { return 0; }
  function date() { printf '20260101_010203\n'; }
  function docker() {
    if [ "${1:-}" = ps ]; then
      [ "$*" = 'ps -a --no-trunc --filter name=^/nginx-capture$ --format {{.ID}}' ] || fail 'unexpected mocked capture listing'
      return 0
    fi
    [ "${1:-}" = run ] || fail 'unexpected mocked Docker operation'
    printf '%s\0' "$@" >"$CASE_DIR/docker.argv"
  }
}

function expect_capture_argv() {
  local folder="$1"
  shift
  printf '%s\0' run -d --name nginx-capture --net=container:nginx-proxy \
    -v "$folder:/pcaps" capture:test tcpdump -U -i any -s0 \
    -w /pcaps/20260101_010203_nginx.pcap "$@" >"$CASE_DIR/expected.argv"
  cmp -s "$CASE_DIR/expected.argv" "$CASE_DIR/docker.argv" ||
    fail 'capture mount/filter argv changed literal folder bytes'
}

function capture_cli_folder() {
  mock_capture_runtime
  local folder="$CAPTURE_DIR/"$'sample\n'
  mkdir -p "$CAPTURE_DIR/sample"
  printf 'keep\n' >"$CAPTURE_DIR/sample/marker"
  start_capture --scope all --folder "$folder" >"$CASE_DIR/capture.log"
  expect_capture_argv "$folder"
  [ -d "$folder" ] && [ -f "$CAPTURE_DIR/sample/marker" ] ||
    fail 'capture created the wrong folder or touched its sibling'
}

function capture_cli_client_folder() {
  mock_capture_runtime
  local folder="$CAPTURE_DIR/"$'first\nsecond\n'
  start_capture --clients 198.51.100.10 --folder "$folder" >"$CASE_DIR/capture.log"
  expect_capture_argv "$folder" '(' host 198.51.100.10 ')'
}

function capture_cli_missing_nested_folder() {
  mock_capture_runtime
  local folder="$CAPTURE_DIR/"$'missing\npart/leaf\n'
  start_capture --scope all --folder "$folder" >"$CASE_DIR/capture.log"
  expect_capture_argv "$folder"
  [ -d "$folder" ] || fail 'capture did not create exact missing nested path'
  [ ! -e "$CAPTURE_DIR/missing" ] || fail 'capture created truncated nested sibling'
}

function capture_interactive_folder() {
  mock_capture_runtime
  INTERACTIVE=true
  function choose_option() { printf -v "$1" '%s' 0; }
  local folder="$CAPTURE_DIR/"$'sample\n'
  printf 'n\n' >"$CASE_DIR/input"
  start_capture "$folder" <"$CASE_DIR/input" >"$CASE_DIR/capture.log"
  expect_capture_argv "$folder"
}

function capture_containment_control() {
  mock_capture_runtime
  expect_rejected start_capture --scope all --folder "$CASE_DIR/sibling"
  [ ! -e "$CASE_DIR/docker.argv" ] || fail 'outside-capture-root request reached runtime'
  [ ! -e "$CASE_DIR/sibling" ] || fail 'rejected capture request created sibling'
}

function invalid_input_status() {
  expect_rejected _runtime_path_to_absolute_lexical ''
  expect_rejected _realpath_portable ''
  expect_rejected _realpath_portable "$CASE_DIR/missing-parent/leaf"
  expect_rejected _capture_resolve_output_path literal_output ''
}

if [ "${1:-}" = --case ]; then
  CASE_NAME="$2"
  CASE_DIR="$3"
  mkdir "$CASE_DIR"
  STATE_DIR="$CASE_DIR/state"
  BASE_DIR="$CASE_DIR"
  CAPTURE_DIR="$STATE_DIR/pcaps"
  TMP_DIR="$STATE_DIR/tmp"
  mkdir "$STATE_DIR"
  "$CASE_NAME"
  exit 0
fi

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-literal-path.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
trap 'rm -rf "$TEST_ROOT"' EXIT
CASES=(
  lexical_bytes relative_lexical_bytes declared_suffix_bytes
  physical_paths physical_fallback fallback_native_readlink
  fallback_gnu_readlink fallback_bsd_readlink failed_readlink_keeps_traps
  missing_path_bytes guard_rejects_literal_link guard_accepts_literal_directory
  guard_rechecks_after_replacement guard_missing_and_containment state_root_ends_in_newline
  delete_directory_bytes delete_file_bytes delete_missing_and_boundary
  delete_final_link delete_spaces_options_embedded
  capture_resolver_bytes capture_missing_bytes
  capture_missing_duplicate_separators capture_missing_duplicate_separators_with_newlines
  capture_cli_folder
  capture_cli_client_folder capture_cli_missing_nested_folder capture_interactive_folder
  capture_containment_control invalid_input_status
)
FAILURES=0
for case_name in "${CASES[@]}"; do
  if "$BASH" "$0" --case "$case_name" "$TEST_ROOT/$case_name" >"$TEST_ROOT/$case_name.log" 2>&1; then
    printf '[tests] literal-path PASS: %s\n' "$case_name"
  else
    printf '[tests] literal-path FAIL: %s\n' "$case_name" >&2
    cat "$TEST_ROOT/$case_name.log" >&2
    FAILURES=$((FAILURES + 1))
  fi
done
[ "$FAILURES" -eq 0 ] || exit 1
printf '[tests] literal_path_identity.sh: PASS (%s cases)\n' "${#CASES[@]}"
