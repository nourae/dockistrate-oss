#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-csv-formatting.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
export LC_ALL=C

# Frozen formatter behavior before the per-field subshell optimization. These
# independent copies also provide the native shell's write-failure reference.
function legacy_csv_escape_field() {
  local field="${1-}"
  local needs_quote=0
  case "$field" in
  *","* | *"\""* | *$'\n'* | *$'\r'*) needs_quote=1 ;;
  esac
  case "$field" in
  " "* | *" " | $'\t'* | *$'\t') needs_quote=1 ;;
  esac
  if [ "$needs_quote" -eq 1 ]; then
    field="${field//\"/\"\"}"
    printf '"%s"' "$field"
  else
    printf '%s' "$field"
  fi
}

# Called with arguments through compare_formatter and in fresh failure probes.
# shellcheck disable=SC2120
function legacy_csv_join_row() {
  local out="" field escaped="" first_field=true
  if [ "$#" -eq 0 ]; then
    printf '\n'
    return 0
  fi
  for field in "$@"; do
    escaped="$(legacy_csv_escape_field "$field")"
    if [ "$first_field" = true ]; then
      out="$escaped"
      first_field=false
    else
      out="${out},${escaped}"
    fi
  done
  printf '%s\n' "$out"
}

declare -f legacy_csv_escape_field legacy_csv_join_row >"$FIXTURE/legacy.sh"

function fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function compare_formatter() {
  local formatter="$1" legacy_status=0 actual_status=0
  shift
  "legacy_$formatter" "$@" >"$CASE_DIR/legacy" || legacy_status=$?
  "$formatter" "$@" >"$CASE_DIR/actual" || actual_status=$?
  [ "$legacy_status" -eq "$actual_status" ] || fail "$formatter changed status"
  cmp -s "$CASE_DIR/legacy" "$CASE_DIR/actual" || fail "$formatter changed output bytes"
}

function expect_row() {
  local expected="$1"
  shift
  compare_formatter csv_join_row "$@"
  printf '%s' "$expected" >"$CASE_DIR/expected"
  cmp -s "$CASE_DIR/expected" "$CASE_DIR/actual" || fail 'row does not match independent expected bytes'
}

function empty_fields() {
  expect_row $'\n'
  expect_row $'\n' ''
  expect_row $',,,\n' '' '' '' ''
  expect_row $',middle,\n' '' middle ''
  compare_formatter csv_escape_field
  [ ! -s "$CASE_DIR/actual" ] || fail 'missing field emitted output'
  compare_formatter csv_escape_field '' ignored
  [ ! -s "$CASE_DIR/actual" ] || fail 'field formatter consumed additional arguments'
}

function quote_boundaries() {
  expect_row $'plain,interior space,interior\ttab," leading","trailing ","\tleading","trailing\t"\n' \
    plain 'interior space' $'interior\ttab' ' leading' 'trailing ' $'\tleading' $'trailing\t'
  expect_row $'"a,b","a""b","a\rb","a\nb","""",","," ","\t"\n' \
    'a,b' 'a"b' $'a\rb' $'a\nb' '"' ',' ' ' $'\t'
  local field=""
  for field in plain ' leading' 'trailing ' $'\tleading' $'trailing\t' 'a,b' 'a"b' $'a\rb' $'a\nb'; do
    compare_formatter csv_escape_field "$field"
  done
}

function multiline_round_trip() {
  local encoded="" index=0 field=""
  local expected=("" $'\n' $'tail\n\n' $'\r\n' $'a,"b"\r\nc\n' '')
  compare_formatter csv_join_row "${expected[@]}"
  # The final record separator is removed here; field newlines remain quoted.
  encoded="$(cat "$CASE_DIR/actual")"
  csv_parse_line "$encoded" || fail 'multiline row could not be parsed'
  [ "$CSV_FIELD_COUNT" -eq "${#expected[@]}" ] || fail 'multiline row lost fields'
  for field in "${expected[@]}"; do
    [ "${CSV_FIELDS[$index]}" = "$field" ] || fail 'multiline round trip changed bytes'
    index=$((index + 1))
  done
}

function byte_corpus() {
  local number=1 octal="" byte=""
  # Bash strings cannot contain NUL. Exercise every other byte in the C locale,
  # including invalid UTF-8, without text utilities normalizing the output.
  while [ "$number" -le 255 ]; do
    printf -v octal '%03o' "$number"
    printf -v byte '%b' "\\$octal"
    compare_formatter csv_escape_field "$byte"
    compare_formatter csv_join_row "$byte" "left${byte}right" "$byte$byte" ''
    number=$((number + 1))
  done
}

function literal_shell_payloads() {
  local payload='$(touch $CASE_DIR/expanded) `touch $CASE_DIR/backtick` ${HOME} *?[glob] \\ -n %s'
  expect_row "$payload"$'\n' "$payload"
  [ ! -e "$CASE_DIR/expanded" ] || fail 'command substitution in data executed'
  [ ! -e "$CASE_DIR/backtick" ] || fail 'backticks in data executed'
  local field='field caller' out='out caller' escaped='escaped caller' first_field='first caller'
  compare_formatter csv_join_row "$field" "$out" "$escaped" "$first_field"
  [ "$field" = 'field caller' ] && [ "$out" = 'out caller' ] &&
    [ "$escaped" = 'escaped caller' ] && [ "$first_field" = 'first caller' ] ||
    fail 'formatter overwrote caller variables'
}

function realistic_state_rows() {
  expect_row $'NGINX_DOCKER_OPTS,"--env JSON={""keys"":[""a,b"",""c""]} --label note=hello"\n' \
    NGINX_DOCKER_OPTS '--env JSON={"keys":["a,b","c"]} --label note=hello'
  expect_row $'example.com,example/image:tag,8080,,"/certs/team, one.pem",false\n' \
    example.com example/image:tag 8080 '' '/certs/team, one.pem' false
  expect_row $'set-header,example.com,X-Example,"say ""hello"", then continue",\n' \
    set-header example.com X-Example 'say "hello", then continue' ''
}

function fail_csv_caller_state() {
  printf '[diagnostic] Expected synthetic caller variables:\n' >&2
  cat "$probe_dir/variables.before" >&2
  printf '[diagnostic] Actual synthetic caller variables:\n' >&2
  declare -p BASH_REMATCH CSV_FIELDS CSV_FIELD_COUNT CSV_PARSE_ERROR >&2 || :
  printf '[diagnostic] IFS expected=%q actual=%q; flags expected=%q actual=%q\n' \
    "$unusual_ifs" "$IFS" "$saved_flags" "$-" >&2
  fail "$*"
}

function assert_csv_caller_values() {
  [ "${#BASH_REMATCH[@]}" -eq 3 ] &&
    [ "${BASH_REMATCH[0]-}" = before123 ] && [ "${BASH_REMATCH[1]-}" = before ] &&
    [ "${BASH_REMATCH[2]-}" = 123 ] || fail_csv_caller_state 'formatter changed BASH_REMATCH values or indices'
  [ "${#CSV_FIELDS[@]}" -eq 2 ] && [ "${CSV_FIELDS[0]-}" = 'prior,field' ] &&
    [ "${CSV_FIELDS[1]-}" = $'prior\nfield' ] || fail_csv_caller_state 'formatter changed CSV_FIELDS values or indices'
  [ "$CSV_FIELD_COUNT" = 2 ] && [ "$CSV_PARSE_ERROR" = 'prior error' ] ||
    fail 'formatter changed CSV parser globals'
  [ "$IFS" = "$unusual_ifs" ] || fail_csv_caller_state 'formatter changed IFS'
  [ "$PWD" = "$saved_pwd" ] && [ "$-" = "$saved_flags" ] || fail_csv_caller_state 'formatter changed shell state'
}

function caller_shell_state() {
  local prefix="" phase="" probe_dir="" item=""
  for prefix in legacy_ ''; do
    probe_dir="$CASE_DIR/${prefix:-current}"
    mkdir "$probe_dir"
    (
      local saved_ifs="$IFS" saved_pwd="$PWD" saved_flags="$-" regex_input=before123
      local unusual_ifs=$'|\n\t' failure_status=0
      trap 'printf "ERR\n" >>"$probe_dir/events"' ERR
      trap 'printf "EXIT\n" >>"$probe_dir/events"' EXIT
      [[ "$regex_input" =~ ^(before)([0-9]+)$ ]] || fail 'regex setup failed'
      CSV_FIELDS=('prior,field' $'prior\nfield')
      CSV_FIELD_COUNT=2
      CSV_PARSE_ERROR='prior error'
      declare -p BASH_REMATCH CSV_FIELDS CSV_FIELD_COUNT CSV_PARSE_ERROR >"$probe_dir/variables.before"
      trap -p >"$probe_dir/traps.before"
      set +o >"$probe_dir/options.before"
      shopt -p >"$probe_dir/shopt.before" || :
      for phase in successful closed_stdout; do
        IFS="$unusual_ifs"
        if [ "$phase" = successful ]; then
          "${prefix}csv_join_row" 'a,b' $'tail\n' '' >"$probe_dir/row"
          "${prefix}csv_escape_field" 'a"b' >"$probe_dir/field"
        else
          "${prefix}csv_join_row" 'a,b' >&- 2>"$probe_dir/write.stderr" || failure_status=$?
          [ "$failure_status" -ne 0 ] || fail 'closed stdout accepted a nonempty row'
        fi
        # Inspect actual values before any output: a native stdio write failure
        # can leave buffered bytes which would contaminate declare/trap output.
        assert_csv_caller_values
        if [ "$phase" = closed_stdout ]; then
          printf '%s' '' >"$probe_dir/write.buffered"
          printf '%s\n' "$failure_status" >"$probe_dir/write.status"
        fi
        IFS="$saved_ifs"
        declare -p BASH_REMATCH CSV_FIELDS CSV_FIELD_COUNT CSV_PARSE_ERROR >"$probe_dir/variables.$phase"
        trap -p >"$probe_dir/traps.$phase"
        set +o >"$probe_dir/options.$phase"
        shopt -p >"$probe_dir/shopt.$phase" || :
        for item in variables traps options shopt; do
          if ! cmp -s "$probe_dir/$item.before" "$probe_dir/$item.$phase"; then
            # Only synthetic fixture values and test-owned traps are printed.
            diff -u "$probe_dir/$item.before" "$probe_dir/$item.$phase" >&2 || :
            fail "$item changed after $phase (${prefix:-current})"
          fi
        done
      done
      printf 'AFTER\n' >>"$probe_dir/events"
    )
    printf 'AFTER\nEXIT\n' >"$probe_dir/events.expected"
    cmp -s "$probe_dir/events.expected" "$probe_dir/events" || fail 'formatter changed trap behavior'
  done
  # Native buffering is observed, not assumed empty or discarded. The optimized
  # formatter must match the frozen legacy formatter's exact status and bytes.
  for item in status buffered; do
    cmp -s "$CASE_DIR/legacy_/write.$item" "$CASE_DIR/current/write.$item" ||
      fail "closed stdout changed native $item behavior"
  done
}

function compare_conditional_write_failure() {
  local formatter="$1" scenario="$2" prefix="" status=0 legacy_status=0 actual_status=0
  shift 2
  for prefix in legacy_ ''; do
    status=0
    "$prefix$formatter" "$@" >&- 2>"$CASE_DIR/$prefix$formatter.$scenario.stderr" || status=$?
    # Flush each native stream independently before another formatter runs.
    # Retain the bytes so native buffering cannot hide a behavior difference.
    printf '%s' '' >"$CASE_DIR/$prefix$formatter.$scenario.buffered"
    if [ "$prefix" = legacy_ ]; then legacy_status=$status; else actual_status=$status; fi
  done
  if [ "$scenario" = nonempty ]; then
    [ "$legacy_status" -ne 0 ] || fail 'legacy nonempty write unexpectedly succeeded'
  else
    [ "$legacy_status" -eq 0 ] || fail 'legacy empty-row conditional contract changed'
  fi
  [ "$legacy_status" -eq "$actual_status" ] || fail 'conditional write failure changed status'
  cmp -s "$CASE_DIR/legacy_$formatter.$scenario.buffered" "$CASE_DIR/$formatter.$scenario.buffered" ||
    fail 'conditional write failure changed native buffered bytes'
}

function conditional_write_failure() {
  local formatter=""
  for formatter in csv_escape_field csv_join_row; do
    compare_conditional_write_failure "$formatter" nonempty 'a,"b' $'tail\n'
  done
  # The zero-argument row intentionally returns 0 after printf in a conditional
  # context; retaining this existing behavior does not hide nonempty-row errors.
  compare_conditional_write_failure csv_join_row empty
}

function errexit_write_failure() {
  local formatter="" prefix="" scenario="" legacy_status=0 actual_status=0 status=0
  for formatter in csv_escape_field csv_join_row; do
    for scenario in nonempty empty; do
      for prefix in legacy_ ''; do
        if "$BASH" -Eeuo pipefail -c '
          source "$1/lib/utils/csv.sh"
          source "$2/legacy.sh"
          events="$3"
          trap '\''printf "ERR\n" >>"$events"'\'' ERR
          trap '\''printf "EXIT\n" >>"$events"'\'' EXIT
          if [ "$5" = nonempty ]; then
            "$4" '\''a,"b'\'' >&-
          else
            "$4" >&-
          fi
          printf "AFTER\n" >>"$events"
        ' csv-write-failure "$ROOT_DIR" "$FIXTURE" "$CASE_DIR/$prefix$formatter.$scenario.events" \
          "$prefix$formatter" "$scenario" >"$CASE_DIR/$prefix$formatter.$scenario.stdout" \
          2>"$CASE_DIR/$prefix$formatter.$scenario.stderr"; then
          status=0
        else
          status=$?
        fi
        if [ "$prefix" = legacy_ ]; then legacy_status=$status; else actual_status=$status; fi
      done
      if [ "$scenario" = nonempty ]; then
        [ "$legacy_status" -ne 0 ] || fail 'legacy errexit write unexpectedly succeeded'
      fi
      [ "$legacy_status" -eq "$actual_status" ] || fail 'errexit write failure changed status'
      # Each fresh child captures its native stream independently. Apple Bash 3
      # can retain failed-write bytes; require exact legacy/current equivalence.
      cmp -s "$CASE_DIR/legacy_$formatter.$scenario.stdout" "$CASE_DIR/$formatter.$scenario.stdout" ||
        fail 'errexit write failure changed native stdout bytes'
      cmp -s "$CASE_DIR/legacy_$formatter.$scenario.events" "$CASE_DIR/$formatter.$scenario.events" ||
        fail 'errexit write failure changed traps or continuation'
    done
  done
}

cases=(empty_fields quote_boundaries multiline_round_trip byte_corpus literal_shell_payloads
  realistic_state_rows caller_shell_state conditional_write_failure errexit_write_failure)
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --case ] || fail 'expected --case <name>'
  selected_case=false
  for case_name in "${cases[@]}"; do
    [ "$case_name" != "$2" ] || selected_case=true
  done
  [ "$selected_case" = true ] || fail 'unknown CSV formatting case'
  CASE_DIR="$FIXTURE/$2"
  mkdir "$CASE_DIR"
  "$2"
  exit 0
fi

for case_name in "${cases[@]}"; do
  case_log="$FIXTURE/$case_name.log"
  case_status=0
  # A fresh process avoids Bash 3's inherited EXIT-trap/subshell status quirks.
  # Cases write their expected output to fixtures, so any diagnostic also fails
  # the parent even if a nested shell accidentally reports a successful status.
  "$BASH" "$0" --case "$case_name" >"$case_log" 2>&1 || case_status=$?
  if [ "$case_status" -ne 0 ] || [ -s "$case_log" ]; then
    cat "$case_log" >&2
    fail "CSV formatting case failed: $case_name (status $case_status)"
  fi
  printf '[tests] csv-formatting PASS: %s\n' "$case_name"
done
printf '[tests] CSV formatting tests passed (%s cases).\n' "${#cases[@]}"
