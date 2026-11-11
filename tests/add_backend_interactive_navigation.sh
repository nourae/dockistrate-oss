#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in utils/csv cli/common cli/is_back_input cli/collect_add_backend_interactive; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
function fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function require_valid_var_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]]; }
DEFAULT_NETWORK=dockistrate-net
function get_arg_choices() {
  case "$2" in
  network) printf 'dockistrate-net|Default network\n' ;;
  image) printf 'nginx:alpine|Nginx\n' ;;
  container_port) printf '80|80\n' ;;
  cert_path) printf 'selfsigned|Generate self-signed certificate\n' ;;
  esac
}
function __arg_choices_common_listen_ports() { printf '8080|8080\n__MANUAL__|Enter manually...\n'; }
function assert_host_port_available_or_fail() {
  CHECKS=$((CHECKS + 1)); CHECK_TRANSPORT="$2"
  [ "$BUSY" != true ]
}
function reset_case() {
  PROTOCOL="$1" REDIRECT="$2" TARGET="$3" ACTION="$4"
  EVENTS=() FIRED=false CALLS=0 CHECKS=0 CHECK_TRANSPORT='' BUSY=false EXPOSE=yes
  SELECTED_CMD=stale SELECTED_ARGS=(stale) PROMPT_ARGS_COLLECTED=(stale)
}
function choose_option() {
  local output="$1" prompt="$2" pick=0
  shift 2
  CALLS=$((CALLS + 1)); [ "$CALLS" -lt 80 ] || fail 'Collector looped without progress'
  EVENTS+=("$prompt")
  CLI_CHOICE_CANCEL_REASON=''
  if [ "$prompt" = "$TARGET" ] && [ "$FIRED" = false ]; then
    FIRED=true
    case "$ACTION" in
    back) pick=$(($# - 1)) ;;
    esc | q) CLI_CHOICE_CANCEL_REASON=back; return 1 ;;
    eof) CLI_CHOICE_CANCEL_REASON=eof; return 1 ;;
    esac
  elif [ "$TARGET" = "manual:$prompt" ]; then
    local label=''
    for label in "$@"; do
      [ "$label" != 'Enter manually...' ] || break
      pick=$((pick + 1))
    done
    [ "$pick" -lt "$#" ] || fail "No manual-entry option for $prompt"
  else
    case "$prompt" in
    Protocol:) case "$PROTOCOL" in https) pick=1 ;; tcp) pick=2 ;; udp) pick=3 ;; esac ;;
    'HTTP->HTTPS redirect:') [ "$REDIRECT" != no ] || pick=1 ;;
    'Expose port now:')
      if [ "$EXPOSE" = no ] || { [ "$BUSY" = true ] && [ "$CHECKS" -gt 0 ]; }; then pick=1; fi
      ;;
    esac
  fi
  printf -v "$output" '%s' "$pick"
}
function read_with_editing() {
  READ_WITH_EDITING_CANCEL_REASON=''
  if [ "$TARGET" = text-eof ] || { [[ "$TARGET" == manual:* ]] && [ "$1" != 'Domain: ' ]; }; then
    READ_WITH_EDITING_CANCEL_REASON=eof
  fi
  printf -v "$2" '%s' example.com
}
function read_multiline_with_editing() {
  READ_WITH_EDITING_CANCEL_REASON=''
  case "$TARGET" in
  docker-eof) READ_WITH_EDITING_CANCEL_REASON=eof ;;
  docker-back)
    if [ "$FIRED" = false ]; then FIRED=true; printf -v "$2" '%s' back; return 0; fi
    ;;
  esac
  printf -v "$2" '%s' ''
}
function assert_predecessor() {
  local target="$1" previous="$2" index=0
  for index in "${!EVENTS[@]}"; do
    if [ "${EVENTS[$index]}" = "$target" ]; then
      [ "${EVENTS[$((index + 1))]:-}" = "$previous" ] || fail "$PROTOCOL/$REDIRECT $ACTION at $target did not return to $previous: ${EVENTS[*]}"
      return 0
    fi
  done
  fail "Target prompt $target did not appear"
}
function run_success() {
  if ! collect_add_backend_interactive >/dev/null; then fail 'Collector cancelled unexpectedly'; fi
  [ "$SELECTED_CMD" = add-backend ] && [ "${#SELECTED_ARGS[@]}" = 12 ] || fail 'Collector did not publish complete arguments'
  [ "${SELECTED_ARGS[0]}" = example.com ] && [ "${SELECTED_ARGS[3]}" = "$PROTOCOL" ] || fail 'Collected domain/protocol changed'
}
for ACTION_CASE in back esc q; do
  for PROTOCOL_CASE in http https tcp udp; do
    case "$PROTOCOL_CASE" in
    http) target='WebSocket support:'; previous='Listen port:' ;;
    https) target='WebSocket support:'; previous='HTTP->HTTPS redirect:' ;;
    tcp | udp) target='Expose port now:'; previous='Listen port:' ;;
    esac
    reset_case "$PROTOCOL_CASE" no "$target" "$ACTION_CASE"
    run_success
    assert_predecessor "$target" "$previous"
  done
  reset_case https yes 'WebSocket support:' "$ACTION_CASE"
  run_success
  assert_predecessor 'WebSocket support:' 'Redirect target port:'
  reset_case https yes 'Redirect target port:' "$ACTION_CASE"
  run_success
  assert_predecessor 'Redirect target port:' 'HTTP->HTTPS redirect:'
  reset_case http no 'Listen port:' "$ACTION_CASE"
  run_success
  assert_predecessor 'Listen port:' 'Container port:'
  for pair in 'Protocol:|Domain:' 'Network:|Protocol:' 'Docker image:|Network:' 'Container port:|Docker image:' 'Certificate path (or generate):|Listen port:' 'HTTP->HTTPS redirect:|Certificate path (or generate):' 'Expose port now:|WebSocket support:'; do
    reset_case https yes "${pair%%|*}" "$ACTION_CASE"
    run_success
    assert_predecessor "${pair%%|*}" "${pair#*|}"
  done
done
for target in 'Domain:' 'Protocol:' 'Network:' 'Docker image:' 'Container port:' 'Listen port:' 'Certificate path (or generate):' 'HTTP->HTTPS redirect:' 'Redirect target port:' 'WebSocket support:' 'Expose port now:' text-eof docker-eof 'manual:Network:' 'manual:Docker image:' 'manual:Container port:' 'manual:Listen port:' 'manual:Certificate path (or generate):' 'manual:Redirect target port:'; do
  reset_case https yes "$target" eof
  if collect_add_backend_interactive >/dev/null; then fail "EOF at $target did not cancel"; fi
  [ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" = 0 ] && [ "${#PROMPT_ARGS_COLLECTED[@]}" = 0 ] || fail 'Cancellation left stale command arguments'
done
for ACTION_CASE in back esc q; do
  reset_case http no Domain: "$ACTION_CASE"
  if collect_add_backend_interactive >/dev/null; then fail 'First-step Back did not cancel'; fi
  [ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" = 0 ] || fail 'First-step cancellation retained selection'
done
reset_case http no docker-back back
run_success
[ "${EVENTS[${#EVENTS[@]}-1]}" = 'Expose port now:' ] || fail 'Docker-options Back did not revisit exposure'
reset_case http no '' ''
BUSY=true EXPOSE=no
run_success
[ "$CHECKS" = 0 ] && [ "${SELECTED_ARGS[9]}" = no ] || fail 'Unexposed backend checked host-port availability'
reset_case http no '' ''
BUSY=true
run_success
[ "$CHECKS" = 1 ] && [ "${SELECTED_ARGS[9]}" = no ] || fail 'Busy exposed port did not allow retry without exposure'
assert_predecessor 'Expose port now:' 'Listen port:'
reset_case udp no '' ''
run_success
[ "$CHECKS" = 1 ] && [ "$CHECK_TRANSPORT" = udp ] || fail 'Exposed UDP port was not checked with UDP transport'

# Exercise the actual chooser, screen renderer and line readers together. Only
# backend/image discovery and the read-only host-port probe remain fixture stubs.
(
  for module in utils/validators utils/fs cli/choose_option cli/render_interactive; do
    # shellcheck disable=SC1090
    source "$ROOT_DIR/lib/$module.sh"
  done
  DOCKISTRATE_NO_CLEAR=true
  VERBOSE=false
  REAL_WORK="$(mktemp -d "${TMPDIR:-/tmp}/backend-navigation-real.XXXXXXXX")"
  trap 'rm -rf "$REAL_WORK"' EXIT
  function run_real_success() {
    local label="$1" wanted_protocol="$2" wanted_exposure="$3" input="$4"
    CHECKS=0 CHECK_TRANSPORT=''
    SELECTED_CMD=stale SELECTED_ARGS=(stale) PROMPT_ARGS_COLLECTED=(stale)
    if ! collect_add_backend_interactive >"$REAL_WORK/$label" < <(printf '%s' "$input"); then
      fail "Real input flow failed: $label"
    fi
    [ "$SELECTED_CMD" = add-backend ] && [ "${#SELECTED_ARGS[@]}" = 12 ] || fail "$label did not collect complete arguments"
    [ "${SELECTED_ARGS[0]}" = example.com ] && [ "${SELECTED_ARGS[3]}" = "$wanted_protocol" ] && [ "${SELECTED_ARGS[9]}" = "$wanted_exposure" ] || fail "$label changed final argument values"
    if [ "$wanted_exposure" = no ]; then
      [ "$CHECKS" = 0 ] || fail "$label checked an unexposed host port"
    else
      [ "$CHECKS" = 1 ] || fail "$label skipped its exposed host-port check"
    fi
  }
  function assert_real_predecessor() {
    local file="$1" target="$2" expected="$3" prompt='' saw_target=false
    while IFS= read -r prompt; do
      case "$prompt" in
      'Domain:' | 'Protocol:' | 'Network:' | 'Docker image:' | 'Container port:' | 'Listen port:' \
      | 'Certificate path (or generate):' | 'HTTP->HTTPS redirect:' | 'Redirect target port:' | 'WebSocket support:' | 'Expose port now:')
        if [ "$saw_target" = true ]; then
          [ "$prompt" = "$expected" ] || fail "Real renderer returned from $target to $prompt instead of $expected"
          return 0
        fi
        [ "$prompt" != "$target" ] || saw_target=true
        ;;
      esac
    done <"$file"
    fail "Real renderer omitted predecessor after $target"
  }
  BUSY=false
  run_real_success http-back http yes $'1\nexample.com\n1\n1\n1\n1\n1\n3\n1\n1\n1\n\n'
  assert_real_predecessor "$REAL_WORK/http-back" 'WebSocket support:' 'Listen port:'
  run_real_success http-q http yes $'1\nexample.com\n1\n1\n1\n1\n1\nq1\n1\n1\n\n'
  assert_real_predecessor "$REAL_WORK/http-q" 'WebSocket support:' 'Listen port:'
  run_real_success https-no-redirect https yes $'1\nexample.com\n2\n1\n1\n1\n1\n1\n2\n3\n2\n1\n1\n\n'
  assert_real_predecessor "$REAL_WORK/https-no-redirect" 'WebSocket support:' 'HTTP->HTTPS redirect:'
  run_real_success https-redirect https yes $'1\nexample.com\n2\n1\n1\n1\n1\n1\n1\n1\n3\n1\n1\n1\n\n'
  assert_real_predecessor "$REAL_WORK/https-redirect" 'WebSocket support:' 'Redirect target port:'
  BUSY=true
  run_real_success tcp-back tcp no $'1\nexample.com\n3\n1\n1\n1\n1\n3\n1\n2\n\n'
  assert_real_predecessor "$REAL_WORK/tcp-back" 'Expose port now:' 'Listen port:'
  run_real_success http-no-expose http no $'1\nexample.com\n1\n1\n1\n1\n1\n1\n2\n\n'
  BUSY=false
  run_real_success udp-back udp yes $'1\nexample.com\n4\n1\n1\n1\n1\n3\n1\n1\n\n'
  assert_real_predecessor "$REAL_WORK/udp-back" 'Expose port now:' 'Listen port:'
  [ "$CHECK_TRANSPORT" = udp ] || fail 'Real UDP flow checked the wrong transport'
  for input in '' $'1\n' $'1\nexample.com\n1\n1\n2\n' \
    $'1\nexample.com\n1\n1\n1\n1\n1\n' \
    $'1\nexample.com\n1\n1\n1\n1\n1\n1\n1\n'; do
    CHECKS=0
    SELECTED_CMD=stale SELECTED_ARGS=(stale) PROMPT_ARGS_COLLECTED=(stale)
    if collect_add_backend_interactive >"$REAL_WORK/eof" < <(printf '%s' "$input"); then
      fail 'Real EOF accepted an incomplete backend'
    fi
    [ -z "$SELECTED_CMD" ] && [ "${#SELECTED_ARGS[@]}" = 0 ] && [ "${#PROMPT_ARGS_COLLECTED[@]}" = 0 ] || fail 'Real EOF retained executable arguments'
  done
)
printf '[tests] add_backend_interactive_navigation.sh: PASS\n'
