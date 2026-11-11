#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-redaction-shapes.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# Exercise the real shared formatting and saved-command callers, without
# sourcing the application entrypoint or touching its runtime state.
for module in utils/common utils/fs utils/csv utils/validators utils/operator_visibility \
  cli/common cli/arg_metadata cli/get_arg_spec cli/command_visibility \
  cli/run_command cli/review_command cli/interactive_recents; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done

DEFAULT_NETWORK=dockistrate-net
NGINX_IMAGE=nginx:alpine
DEFAULT_VISIBILITY_POLICY=full
INTERACTIVE_RECENTS_NOW=2026-01-01T00:00:00+0000
MARKER=DUMMY_REDACTION_SECRET
FAILURES=0
CASES=0

function fail_check() {
  printf '[Error] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

function assert_hidden() {
  case "$2" in
  *"$MARKER"*) fail_check "$1 leaked dummy value" ;;
  esac
}

function assert_visible() {
  case "$2" in
  *"$MARKER"*) ;;
  *) fail_check "$1 lost explicit full-policy value" ;;
  esac
}

function check_sensitive_case() {
  local label="$1" cmd="$2" output="" args_csv="" surface=""
  shift 2
  CASES=$((CASES + 1))
  CONFIG_DIR="$TEST_DIR/case-$CASES"
  mkdir -p "$CONFIG_DIR"
  args_csv="$(_interactive_command_args_csv "$@")"

  VISIBILITY_POLICY=redacted
  for surface in _run_command_audit_message _run_command_verbose_message format_cli_equivalent _review_command_format_arg_summary; do
    output="$("$surface" "$cmd" "$@")"
    assert_hidden "$label $surface" "$output"
    case "$output" in
    *'[REDACTED]'*) ;;
    *) fail_check "$label $surface omitted redaction marker" ;;
    esac
  done
  _run_command_has_sensitive_args "$cmd" "$@" || fail_check "$label run sensitivity missed value"
  interactive_command_has_sensitive_args "$cmd" "$@" || fail_check "$label history sensitivity missed value"

  interactive_record_recent_command "$cmd" "$@"
  interactive_favorite_command "$cmd" "$#" "$args_csv"
  for surface in "$(interactive_recent_file)" "$(interactive_favorites_file)"; do
    if [ -f "$surface" ]; then
      assert_hidden "$label new saved command" "$(cat "$surface")"
    fi
  done

  # Full mode is an intentional operator choice. It must preserve display and
  # exact saved argv, while switching back to redacted hides existing entries.
  VISIBILITY_POLICY=full
  for surface in _run_command_audit_message _run_command_verbose_message format_cli_equivalent _review_command_format_arg_summary; do
    assert_visible "$label $surface" "$("$surface" "$cmd" "$@")"
  done
  if _run_command_has_sensitive_args "$cmd" "$@" || interactive_command_has_sensitive_args "$cmd" "$@"; then
    fail_check "$label unexpectedly suppressed explicit full visibility"
  fi
  interactive_record_recent_command "$cmd" "$@"
  interactive_favorite_command "$cmd" "$#" "$args_csv"
  for surface in interactive_load_recent_commands interactive_load_favorite_commands; do
    "$surface"
    [ "${#INTERACTIVE_SAVED_COMMANDS[@]}" -eq 1 ] || fail_check "$label $surface lost full saved command"
    [ "${INTERACTIVE_SAVED_ARGS_CSV[0]:-}" = "$args_csv" ] || fail_check "$label $surface changed saved argv"
  done
  VISIBILITY_POLICY=redacted
  for surface in interactive_load_recent_commands interactive_load_favorite_commands; do
    "$surface"
    [ "${#INTERACTIVE_SAVED_COMMANDS[@]}" -eq 0 ] || fail_check "$label $surface exposed full-mode saved command"
  done
}

INTERACTIVE=true
check_sensitive_case update-backend-positional update-backend example.com nginx:alpine 8080 "--env TOKEN=$MARKER" dockistrate-net
check_sensitive_case update-backend-option-shaped-image update-backend example.com --image 8080 "--env TOKEN=$MARKER" dockistrate-net
check_sensitive_case positional-control add-backend example.com nginx:alpine 80 https 443 cert yes "--env TOKEN=$MARKER" dockistrate-net yes
check_sensitive_case option-shaped-certificate add-backend example.com nginx:alpine 80 https 443 --mycert yes "--env TOKEN=$MARKER" dockistrate-net yes
check_sensitive_case known-option-shaped-certificate add-backend example.com nginx:alpine 80 https 443 --network yes "--env TOKEN=$MARKER" dockistrate-net yes
check_sensitive_case interactive-trailing-docker-options add-backend example.com nginx:alpine 80 http 8080 none no '' net yes '' '' --docker-opts "--env TOKEN=$MARKER"
check_sensitive_case interactive-malformed-tail add-backend example.com nginx:alpine 80 http 8080 none no '' net yes '' '' "--no-expose=$MARKER"
check_sensitive_case option-shaped-image start-nginx --nginx-image --myimage --docker-opts "--env TOKEN=$MARKER"

INTERACTIVE=false
check_sensitive_case update-backend-options update-backend example.com --network net --image nginx:alpine --container-port 8080 --docker-opts "--env TOKEN=$MARKER"
check_sensitive_case exact-no-expose add-backend example.com nginx:alpine 80 http --docker-opts "--env TOKEN=$MARKER" --no-expose
check_sensitive_case malformed-no-expose add-backend example.com nginx:alpine 80 http --docker-opts --env "--no-expose=$MARKER"
check_sensitive_case early-network add-backend example.com nginx:alpine 80 http --network net '' none no "$MARKER"
check_sensitive_case early-inline-network add-backend example.com nginx:alpine 80 http --network=net '' none no "$MARKER"
check_sensitive_case aliased-certificate add-backend example.com nginx:alpine 80 https --listen 443 --cert --mycert --ws yes --docker-opts "--env TOKEN=$MARKER" --network net
check_sensitive_case first-inline-unknown start-nginx "--unknown=$MARKER" --docker-opts --env
check_sensitive_case empty-docker-option start-nginx --docker-opts '' --env "TOKEN=$MARKER"
check_sensitive_case mixed-header add-header --req-resp response --header X-Token "$MARKER"
check_sensitive_case split-header add-header response Authorization Bearer "$MARKER"
check_sensitive_case variadic-empty set-nginx-docker-opts '' --env "TOKEN=$MARKER" --cpus 1

# The directive command consumes compact, scope-dependent argv in both flows;
# metadata's padded prompt specification is not its execution signature.
for INTERACTIVE in false true; do
  for directive_cmd in set-nginx-directive-raw set-nginx-directive; do
    check_sensitive_case "$INTERACTIVE-$directive_cmd-global" "$directive_cmd" global proxy_set_header "Authorization $MARKER"
    check_sensitive_case "$INTERACTIVE-$directive_cmd-backend" "$directive_cmd" backend example.com proxy_set_header Authorization "$MARKER"
    check_sensitive_case "$INTERACTIVE-$directive_cmd-port" "$directive_cmd" port example.com 443 add_header "X-Token $MARKER"
    check_sensitive_case "$INTERACTIVE-$directive_cmd-path" "$directive_cmd" path example.com 443 /api add_header X-Token "$MARKER"
  done
  check_sensitive_case "$INTERACTIVE-stream-global" set-nginx-directive-raw stream-global proxy_ssl_name "$MARKER"
  check_sensitive_case "$INTERACTIVE-stream-backend" set-nginx-directive-raw stream-backend example.com proxy_ssl_name "$MARKER"
  check_sensitive_case "$INTERACTIVE-stream-port" set-nginx-directive-raw stream-port example.com 8443 proxy_ssl_name "$MARKER"
done

# Harmless clear actions must remain replayable in redacted mode.
VISIBILITY_POLICY=redacted
for clear_cmd in set-hsts set-csp; do
  if _run_command_has_sensitive_args "$clear_cmd" off || interactive_command_has_sensitive_args "$clear_cmd" off; then
    fail_check "$clear_cmd off was classified as a secret"
  fi
done
if _run_command_has_sensitive_args update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__ ||
  interactive_command_has_sensitive_args update-backend example.com --docker-opts __DOCKER_OPTS_CLEAR__; then
  fail_check 'Docker option clear action was classified as a secret'
fi
INTERACTIVE=false
exact_flag_output="$(_run_command_audit_message add-backend example.com nginx:alpine 80 http --docker-opts "--env TOKEN=$MARKER" --no-expose)"
case "$exact_flag_output" in
*'--no-expose') ;;
*) fail_check 'exact no-argument flag disappeared after redacted value' ;;
esac

# Dispatch uses the original array, never its display projection. NUL-delimited
# captures distinguish empty words, spaces, newlines, quotes and glob characters.
function audit_log() { printf '%s\n' "$*" >>"$TEST_DIR/audit.log"; }
function add_backend() { printf '%s\0' "$@" >"$TEST_DIR/dispatched.argv"; }
function set_nginx_directive_raw() { printf '%s\0' "$@" >"$TEST_DIR/dispatched.argv"; }
VERBOSE=true
for VISIBILITY_POLICY in redacted full; do
  args=(example.com nginx:alpine 80 https 443 --mycert yes "--env TOKEN=$MARKER" '' $'a\nb' "a'b" '*')
  printf '%s\0' "${args[@]}" >"$TEST_DIR/expected.argv"
  run_command add-backend "${args[@]}" >"$TEST_DIR/dispatch.stdout" 2>"$TEST_DIR/dispatch.stderr"
  cmp -s "$TEST_DIR/expected.argv" "$TEST_DIR/dispatched.argv" || fail_check "$VISIBILITY_POLICY add-backend dispatch changed argv"
  args=(global proxy_set_header "Authorization $MARKER" '' $'a\nb' "a'b" '*')
  printf '%s\0' "${args[@]}" >"$TEST_DIR/expected.argv"
  run_command set-nginx-directive-raw "${args[@]}" >"$TEST_DIR/dispatch.stdout" 2>"$TEST_DIR/dispatch.stderr"
  cmp -s "$TEST_DIR/expected.argv" "$TEST_DIR/dispatched.argv" || fail_check "$VISIBILITY_POLICY directive dispatch changed argv"
done

# Leading empty words are real argv. CSV round trips must preserve their
# positions so saved-command classification cannot shift a sensitive operand.
for empty_count in 1 2 3; do
  csv_args=()
  for ((idx = 0; idx < empty_count; idx++)); do csv_args+=(""); done
  csv_args+=("$MARKER" 'comma,value' 'quoted"value' '')
  encoded="$(csv_join_row "${csv_args[@]}")"
  csv_parse_line "$encoded" || fail_check 'CSV round trip failed to parse'
  [ "$CSV_FIELD_COUNT" -eq "${#csv_args[@]}" ] || fail_check 'CSV round trip shifted leading empty words'
  for idx in "${!csv_args[@]}"; do
    [ "${CSV_FIELDS[$idx]:-}" = "${csv_args[$idx]}" ] || fail_check 'CSV round trip changed an argument'
  done
done

# Corrupt saved records must not bypass classification through a failed parse.
# These malformed argument counts model old/corrupted state, not valid replay.
VISIBILITY_POLICY=redacted
CONFIG_DIR="$TEST_DIR/malformed-saved"
mkdir -p "$CONFIG_DIR"
malformed_args="$(_interactive_command_args_csv response Authorization "$MARKER")"
interactive_favorite_command add-header 99 "$malformed_args" >"$TEST_DIR/malformed-output" 2>&1 || true
if [ -f "$(interactive_favorites_file)" ]; then
  assert_hidden 'malformed favorite write' "$(cat "$(interactive_favorites_file)")"
fi
{
  printf '%s\n' "$STATE_INTERACTIVE_FAVORITES_HEADER"
  csv_join_row add-header 99 "$malformed_args"
} >"$(interactive_favorites_file)"
{
  printf '%s\n' "$STATE_INTERACTIVE_RECENTS_HEADER"
  csv_join_row "$INTERACTIVE_RECENTS_NOW" add-header 99 "$malformed_args"
} >"$(interactive_recent_file)"
for loader in interactive_load_recent_commands interactive_load_favorite_commands; do
  "$loader" >"$TEST_DIR/malformed-output" 2>&1 || true
  assert_hidden "$loader error output" "$(cat "$TEST_DIR/malformed-output")"
  [ "${#INTERACTIVE_SAVED_COMMANDS[@]}" -eq 0 ] || fail_check "$loader exposed malformed saved secret"
done

# Audit happens before command validation. The real rejection diagnostic must
# also hide an invalid option's inline secret, while full mode remains explicit.
# shellcheck source=../lib/backends/add_backend.sh
source "$ROOT_DIR/lib/backends/add_backend.sh"
INTERACTIVE=false
for VISIBILITY_POLICY in redacted full; do
  for malformed in "--no-expose=$MARKER" "--docker-opts=$MARKER"; do
    if output="$(add_backend example.com nginx:alpine 80 http --docker-opts '--cpus 1' "$malformed" 2>&1)"; then
      fail_check 'actual add-backend accepted a malformed option'
    fi
    if [ "$VISIBILITY_POLICY" = redacted ]; then
      assert_hidden 'actual add-backend rejection' "$output"
    else
      assert_visible 'actual add-backend rejection' "$output"
    fi
  done
done

[ "$FAILURES" -eq 0 ] || { printf '[Error] %s redaction assertions failed\n' "$FAILURES" >&2; exit 1; }
printf '[tests] redaction_command_shapes.sh: PASS (%s sensitive cases)\n' "$CASES"
