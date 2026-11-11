#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/runtime_paths.sh
source "$ROOT_DIR/lib/runtime_paths.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-path-assignment.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT

function fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function equal() {
  [ "$1" = "$2" ] || fail "${3:-literal bytes differ}"
}

function stdout_equals() {
  local expected_bytes="$1"
  shift
  printf '%s' "$expected_bytes" >"$CASE_DIR/expected"
  "$@" >"$CASE_DIR/actual" || fail "stdout helper failed: $1"
  cmp -s "$CASE_DIR/expected" "$CASE_DIR/actual" || fail "stdout bytes changed: $1"
}

function trim_bytes() {
  local item="" result=""
  for item in plain $'line\n' $'line\n\n' $'line\r\t\n' 'with spaces' '*?[glob]' '-option' 'a//b'; do
    _runtime_path_strip_trailing_slashes_assign result "$item///"
    equal "$item" "$result" 'trim assignment changed pathname bytes'
    stdout_equals "$item" _runtime_path_strip_trailing_slashes "$item///"
  done
  _runtime_path_strip_trailing_slashes_assign result ''
  equal '' "$result" 'empty trim result'
}

function absolute_bytes() {
  local item="" result=""
  for item in /plain $'/line\n' $'/line\n\n' $'/line\r\t\n' '/with spaces' '/*?[glob]' '/a//b'; do
    _runtime_path_to_absolute_lexical_assign result "$item///"
    equal "$item" "$result" 'absolute assignment changed pathname bytes'
    stdout_equals "$item" _runtime_path_to_absolute_lexical "$item///"
  done
}

function relative_bytes() {
  local item="" result="" PWD=$'/literal parent\n'
  for item in plain $'leaf\n\n' $'leaf\r\t' '*?[glob]' './leaf' '../leaf' 'a//b'; do
    _runtime_path_to_absolute_lexical_assign result "$item///"
    equal "$PWD/$item" "$result" 'relative assignment changed literal PWD or input'
    stdout_equals "$PWD/$item" _runtime_path_to_absolute_lexical "$item///"
  done
}

function root_and_double_slashes() {
  local result="" PWD=/ STATE_DIR=/
  _runtime_path_strip_trailing_slashes_assign result ////
  equal / "$result"
  _runtime_path_to_absolute_lexical_assign result /
  equal / "$result"
  _runtime_path_to_absolute_lexical_assign result leaf
  equal //leaf "$result" 'PWD=/ prefix behavior changed'
  _runtime_path_to_absolute_lexical_assign result //leaf///
  equal //leaf "$result" 'leading double slash normalized'
  _runtime_state_declared_suffix_assign result /
  equal '' "$result"
  _runtime_state_declared_suffix_assign result //leaf///
  equal /leaf "$result"
  stdout_equals //leaf _runtime_path_to_absolute_lexical leaf
}

function suffix_bytes() {
  local result="" STATE_DIR=$'/state *?\r\t\n' item=""
  for item in plain $'leaf\n\n' $'leaf\r\t' 'with spaces' '*?[glob]' 'a//b'; do
    _runtime_state_declared_suffix_assign result "$STATE_DIR/$item///"
    equal "/$item" "$result" 'declared suffix changed bytes'
    stdout_equals "/$item" _runtime_state_declared_suffix "$STATE_DIR/$item///"
  done
  _runtime_state_declared_suffix_assign result "$STATE_DIR///"
  equal '' "$result" 'state root suffix must be empty'
  STATE_DIR=relative
  _runtime_state_declared_suffix_assign result 'relative/leaf'
  equal /leaf "$result"
}

function same_variable() {
  local value=$'/first\n\n///' STATE_DIR=$'/first\n\n'
  _runtime_path_strip_trailing_slashes_assign value "$value"
  equal "$STATE_DIR" "$value"
  value=$'relative\n///'
  _runtime_path_to_absolute_lexical_assign value "$value"
  equal "$PWD/"$'relative\n' "$value"
  value="$STATE_DIR/"$'leaf\n///'
  _runtime_state_declared_suffix_assign value "$value"
  equal $'/leaf\n' "$value"
}

function common_caller_names() {
  # Assigned and inspected by their dynamic destination names below.
  # shellcheck disable=SC2034
  local path="" root="" abs_path="" abs_root="" declared_suffix="" __out_var=""
  local destination="" STATE_DIR=/state
  for destination in path root abs_path abs_root declared_suffix __out_var; do
    printf -v "$destination" '%s' before
    _runtime_path_strip_trailing_slashes_assign "$destination" $'leaf\n///'
    equal $'leaf\n' "${!destination}" "trim shadowed caller $destination"
    _runtime_path_to_absolute_lexical_assign "$destination" $'leaf\n///'
    equal "$PWD/"$'leaf\n' "${!destination}" "absolute shadowed caller $destination"
    _runtime_state_declared_suffix_assign "$destination" $'/state/leaf\n///'
    equal $'/leaf\n' "${!destination}" "suffix shadowed caller $destination"
  done
}

# The assignment helpers deliberately create these initially unset variables.
# shellcheck disable=SC2154
function unset_destinations() {
  local STATE_DIR=/state
  unset assignment_new_trim assignment_new_absolute assignment_new_suffix
  _runtime_path_strip_trailing_slashes_assign assignment_new_trim $'leaf\n///'
  _runtime_path_to_absolute_lexical_assign assignment_new_absolute $'leaf\n///'
  _runtime_state_declared_suffix_assign assignment_new_suffix $'/state/leaf\n///'
  equal $'leaf\n' "$assignment_new_trim"
  equal "$PWD/"$'leaf\n' "$assignment_new_absolute"
  equal $'/leaf\n' "$assignment_new_suffix"
}

function reserved_scratch_names() {
  local _runtime_trim_value=before _runtime_absolute_value=before
  local _runtime_suffix_path=before _runtime_suffix_root=before _runtime_suffix_value=before
  local helper="" destination="" STATE_DIR=/state
  for destination in _runtime_trim_value _runtime_absolute_value _runtime_suffix_path _runtime_suffix_root _runtime_suffix_value; do
    case "$destination" in
    _runtime_trim_value) helper=_runtime_path_strip_trailing_slashes_assign ;;
    _runtime_absolute_value) helper=_runtime_path_to_absolute_lexical_assign ;;
    *) helper=_runtime_state_declared_suffix_assign ;;
    esac
    if "$helper" "$destination" /state/leaf >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"; then
      fail "reserved scratch destination succeeded: $destination"
    fi
    equal before "${!destination}" "reserved scratch destination was modified: $destination"
    [ ! -s "$CASE_DIR/stdout" ] && [ ! -s "$CASE_DIR/stderr" ] || fail 'reserved destination caused side effects'
  done
}

function cross_helper_scratch_names() {
  local _runtime_trim_value=before _runtime_absolute_value=before STATE_DIR=/state
  _runtime_path_strip_trailing_slashes_assign _runtime_absolute_value $'leaf\n///'
  equal $'leaf\n' "$_runtime_absolute_value"
  _runtime_path_to_absolute_lexical_assign _runtime_trim_value $'leaf\n///'
  equal "$PWD/"$'leaf\n' "$_runtime_trim_value"
  _runtime_state_declared_suffix_assign _runtime_trim_value $'/state/leaf\n///'
  equal $'/leaf\n' "$_runtime_trim_value"
  _runtime_state_declared_suffix_assign _runtime_absolute_value $'/state/leaf\n///'
  equal $'/leaf\n' "$_runtime_absolute_value"
}

function invalid_destinations() {
  local destination="" helper="" unchanged=before STATE_DIR=/state
  local arr=(first second)
  function assignment_side_effect() { : >"$CASE_DIR/executed"; printf 0; }
  for helper in _runtime_path_strip_trailing_slashes_assign _runtime_path_to_absolute_lexical_assign _runtime_state_declared_suffix_assign; do
    for destination in '' 1bad a-b 'a b' $'a\n' 'arr[0]' 'arr[$(assignment_side_effect)]' 'unchanged=bad' 'unchanged;assignment_side_effect' 'a.b'; do
      if "$helper" "$destination" /state/leaf >"$CASE_DIR/stdout" 2>"$CASE_DIR/stderr"; then
        fail "invalid destination accepted: $destination"
      fi
      equal before "$unchanged" 'invalid destination modified caller'
      equal first "${arr[0]}" 'array destination modified element zero'
      equal second "${arr[1]}" 'array destination modified element one'
      [ ! -e "$CASE_DIR/executed" ] || fail 'destination expression was executed'
      [ ! -s "$CASE_DIR/stdout" ] || fail 'invalid destination published output'
    done
  done
}

function failure_preserves_output() {
  local value=before STATE_DIR=/state
  if _runtime_path_to_absolute_lexical_assign value; then fail 'missing absolute input accepted'; fi
  equal before "$value"
  if _runtime_state_declared_suffix_assign value; then fail 'missing suffix input accepted'; fi
  equal before "$value"
  if _runtime_state_declared_suffix_assign value /state-other/leaf; then fail 'sibling prefix accepted'; fi
  equal before "$value"
  if _runtime_state_declared_suffix_assign value /outside; then fail 'outside path accepted'; fi
  equal before "$value"
  unset STATE_DIR
  if _runtime_state_declared_suffix_assign value /state/leaf; then fail 'missing state accepted'; fi
  equal before "$value"
  _runtime_path_strip_trailing_slashes_assign value
  equal '' "$value" 'empty trimming contract changed'
}

function caller_shell_state() {
  (
    local value=before STATE_DIR=/state saved_pwd="$PWD" saved_flags="$-" match_input=match-42
    IFS=$' \t\n:'
    local saved_ifs="$IFS"
    [[ "$match_input" =~ ([a-z]+)-([0-9]+) ]]
    declare -p BASH_REMATCH >"$CASE_DIR/rematch.before"
    trap 'printf "ERR\n" >>"$CASE_DIR/events"' ERR
    trap 'printf "EXIT\n" >>"$CASE_DIR/events"' EXIT
    trap -p ERR EXIT >"$CASE_DIR/traps.before"
    set +o >"$CASE_DIR/options.before"
    shopt -p >"$CASE_DIR/shopt.before" || :
    _runtime_path_strip_trailing_slashes_assign value $'leaf\n///'
    _runtime_path_to_absolute_lexical_assign value "$value"
    _runtime_state_declared_suffix_assign value /state/leaf
    if _runtime_path_to_absolute_lexical_assign value ''; then fail 'empty input accepted'; fi
    if _runtime_state_declared_suffix_assign value /outside; then fail 'outside input accepted'; fi
    if _runtime_path_strip_trailing_slashes_assign 'bad[0]' value; then fail 'array syntax accepted'; fi
    declare -p BASH_REMATCH >"$CASE_DIR/rematch.after"
    trap -p ERR EXIT >"$CASE_DIR/traps.after"
    set +o >"$CASE_DIR/options.after"
    shopt -p >"$CASE_DIR/shopt.after" || :
    equal "$saved_pwd" "$PWD" 'PWD changed'
    equal "$saved_ifs" "$IFS" 'IFS changed'
    equal "$saved_flags" "$-" 'shell flags changed'
    local item=""
    for item in rematch traps options shopt; do
      cmp -s "$CASE_DIR/$item.before" "$CASE_DIR/$item.after" || fail "$item changed"
    done
    printf 'AFTER\n' >>"$CASE_DIR/events"
  )
  printf 'AFTER\nEXIT\n' >"$CASE_DIR/expected-events"
  cmp -s "$CASE_DIR/expected-events" "$CASE_DIR/events" || fail 'expected failure triggered ERR or lost EXIT'
}

function readonly_failure() {
  local helper="" status=0 native_status=""
  # Apple Bash 3 can report success after printf -v refuses a readonly write.
  # Match that native status while requiring the refusal and unchanged bytes.
  for helper in native_printf _runtime_path_strip_trailing_slashes_assign _runtime_path_to_absolute_lexical_assign _runtime_state_declared_suffix_assign; do
    if LC_ALL=C "$BASH" -Eeuo pipefail -c '
      source "$1/lib/runtime_paths.sh"
      readonly assignment_readonly=before
      STATE_DIR=/state
      assignment_readonly_receipt="$2"
      trap '\''printf "%s" "$assignment_readonly" >"$assignment_readonly_receipt"'\'' EXIT
      if [ "$3" = native_printf ]; then
        builtin printf -v assignment_readonly "%s" /state/leaf
      else
        "$3" assignment_readonly /state/leaf
      fi
    ' assignment-readonly "$ROOT_DIR" "$CASE_DIR/$helper.readonly" "$helper" >"$CASE_DIR/$helper.stdout" 2>"$CASE_DIR/$helper.stderr"; then
      status=0
    else
      status=$?
    fi
    printf before >"$CASE_DIR/expected"
    cmp -s "$CASE_DIR/expected" "$CASE_DIR/$helper.readonly" || fail "readonly variable changed: $helper"
    [ ! -s "$CASE_DIR/$helper.stdout" ] || fail "readonly failure published output: $helper"
    LC_ALL=C grep -F 'assignment_readonly: readonly variable' "$CASE_DIR/$helper.stderr" >/dev/null || fail "readonly refusal diagnostic missing: $helper"
    if [ "$helper" = native_printf ]; then
      native_status="$status"
    else
      equal "$native_status" "$status" "readonly status differs from native printf: $helper"
    fi
  done
}

function stdout_failure_contract() {
  local STATE_DIR=/state
  if _runtime_path_to_absolute_lexical '' >"$CASE_DIR/stdout"; then fail 'empty wrapper input succeeded'; fi
  [ ! -s "$CASE_DIR/stdout" ] || fail 'failed absolute wrapper published bytes'
  if _runtime_state_declared_suffix /outside >"$CASE_DIR/stdout"; then fail 'outside wrapper input succeeded'; fi
  [ ! -s "$CASE_DIR/stdout" ] || fail 'failed suffix wrapper published bytes'
  # The existing declared-suffix stdout wrapper explicitly returns success after
  # printf when invoked conditionally; retain that status contract here.
  if _runtime_state_declared_suffix /state/leaf >&- 2>/dev/null; then
    :
  else
    fail 'declared suffix conditional write-failure status changed'
  fi
}

cases=(trim_bytes absolute_bytes relative_bytes root_and_double_slashes suffix_bytes
  same_variable common_caller_names unset_destinations reserved_scratch_names
  cross_helper_scratch_names invalid_destinations failure_preserves_output
  caller_shell_state readonly_failure stdout_failure_contract)
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --case ] || fail 'expected --case <name>'
  selected_case=false
  for case_name in "${cases[@]}"; do
    [ "$case_name" != "$2" ] || selected_case=true
  done
  [ "$selected_case" = true ] || fail 'unknown runtime path assignment case'
  CASE_DIR="$FIXTURE/$2"
  mkdir "$CASE_DIR"
  "$2"
  exit 0
fi

for case_name in "${cases[@]}"; do
  case_log="$FIXTURE/$case_name.log"
  case_status=0
  # Fresh processes keep Bash 3's inherited EXIT trap from masking a failed
  # case. Check captured output too, so nested failures cannot report PASS.
  "$BASH" "$0" --case "$case_name" >"$case_log" 2>&1 || case_status=$?
  if [ "$case_status" -ne 0 ]; then
    cat "$case_log" >&2
    fail "Runtime path assignment case failed: $case_name (status $case_status)"
  fi
  if [ -s "$case_log" ]; then
    case "${OSTYPE:-}:${BASH_VERSINFO[0]}:$case_name" in
    darwin*:3:stdout_failure_contract)
      # Native Apple Bash 3 can expose these exact bytes from the existing
      # conditional closed-stdout probe. Audit them without leaking a prefix
      # into the PASS marker; every other diagnostic remains a failure.
      printf /leaf >"$FIXTURE/native-stdout.expected"
      if ! cmp -s "$FIXTURE/native-stdout.expected" "$case_log"; then
        cat "$case_log" >&2
        fail "Unexpected native stdout failure output: $case_name"
      fi
      ;;
    *)
      cat "$case_log" >&2
      fail "Unexpected runtime path assignment output: $case_name"
      ;;
    esac
  fi
  printf '[tests] runtime-path-assignment PASS: %s\n' "$case_name"
done
printf '[tests] Runtime path assignment tests passed (%s cases).\n' "${#cases[@]}"
