#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-key-cli.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
trap 'rm -rf "$TEST_DIR"' EXIT
CHECKOUT="$TEST_DIR/checkout"
TARGET="$TEST_DIR/alternate keys"
DOCKER_TRACE="$TEST_DIR/docker.trace"
export DOCKER_TRACE
mkdir -p "$CHECKOUT" "$TARGET" "$TEST_DIR/bin"
# Copy only application source; no original runtime/operator files enter the
# disposable checkout. This executes the real CLI bootstrap and dispatch path.
cp "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$CHECKOUT/"
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$CHECKOUT/"
chmod 700 "$CHECKOUT/dockistrate.sh"
cat >"$TEST_DIR/bin/docker" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' 'unexpected Docker call' >>"$DOCKER_TRACE"
exit 99
SHIM
chmod 700 "$TEST_DIR/bin/docker"

function mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

function assert_mode() {
  local actual=""
  actual="$(mode_of "$1")"
  [ "$actual" = "$2" ] || {
    fail_test "$3: mode $actual, expected $2"
  }
}

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  [ ! -f "$TEST_DIR/output" ] || cat "$TEST_DIR/output" >&2
  exit 1
}

function run_repair() {
  PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
    "$BASH" "$CHECKOUT/dockistrate.sh" fix-permissions "$TARGET" >"$TEST_DIR/output" 2>&1
}

# Drive the real picker using its declared menu positions. Input is piped so
# this regression can run on CI without a terminal or an extra PTY dependency.
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
advanced_choice='' basic_choice='' repair_choice='' runtime_choice='' visibility_choice='' cancel_choice='' favorites_choice=''
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_HOME_OPTIONS[@]}; idx++)); do
  if [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$idx]}" = "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL" ]; then
    advanced_choice=$((idx + 1))
  fi
  if [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$idx]}" = "$INTERACTIVE_PICKER_HOME_FAVORITES_LABEL" ]; then
    favorites_choice=$((idx + 1))
  fi
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_CATEGORIES[@]}; idx++)); do
  case "${INTERACTIVE_PICKER_CATEGORIES[$idx]}" in
  'Basic Ops') basic_choice=$((idx + 2)) ;;
  'Global TLS & Runtime') runtime_choice=$((idx + 2)) ;;
  esac
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_COMMANDS_BASIC[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_COMMANDS_BASIC[$idx]}" != fix-permissions ] || repair_choice=$((idx + 1))
done
for ((idx = 0; idx < ${#INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME[@]}; idx++)); do
  [ "${INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME[$idx]}" != show-visibility-policy ] || visibility_choice=$((idx + 1))
  [ "${INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME[$idx]}" != set-http-version ] || cancel_choice=$((idx + 1))
done
for choice in "$advanced_choice" "$basic_choice" "$repair_choice" "$runtime_choice" "$visibility_choice" "$cancel_choice" "$favorites_choice"; do
  [ -n "$choice" ] || fail_test 'required picker choices are missing'
done

function repair_picker_input() {
  printf '%s\n%s\n%s\n3\n%s\n1\n\n' "$advanced_choice" "$basic_choice" "$repair_choice" "${1:-$TARGET}"
}

function run_verbose_picker_repair() {
  { repair_picker_input; printf 'q\n'; } | PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
    "$BASH" "$CHECKOUT/dockistrate.sh" -v -i >"$TEST_DIR/output" 2>&1
}

function assert_unrelated_state_unchanged() {
  assert_mode "$CHECKOUT/dockistrate.sh" 700 'unrelated entrypoint'
  assert_mode "$CHECKOUT/state/config/global_settings.csv" 666 'unrelated settings'
  assert_mode "$CHECKOUT/state/logs/docker_manager.log" 644 'unrelated log'
  assert_mode "$CHECKOUT/state/certs/active.key" 644 'unrelated active key'
  for dir in "$CHECKOUT/state" "$CHECKOUT/state/config" "$CHECKOUT/state/logs" "$CHECKOUT/state/certs"; do
    assert_mode "$dir" 700 'unrelated runtime directory'
  done
  cmp -s "$CHECKOUT/state/config/global_settings.csv" "$TEST_DIR/settings-before" || fail_test 'repair changed unrelated settings contents'
  cmp -s "$CHECKOUT/state/logs/docker_manager.log" "$TEST_DIR/log-before" || fail_test 'repair wrote to unrelated log'
  for path in state/tmp state/backups state/pcaps state/acme-webroot state/config/state_schema_version state/logs/audit.log; do
    [ ! -e "$CHECKOUT/$path" ] || fail_test "repair created unrelated $path"
  done
  [ ! -s "$DOCKER_TRACE" ] || fail_test 'alternate-target repair invoked Docker'
}

mkdir -p "$CHECKOUT/state/config" "$CHECKOUT/state/logs" "$CHECKOUT/state/certs"
printf '%s\n' 'key,value' 'NGINX_IMAGE,operator.example/nginx:custom' >"$CHECKOUT/state/config/global_settings.csv"
printf '%s\n' 'existing log must remain unchanged' >"$CHECKOUT/state/logs/docker_manager.log"
printf '%s\n' 'DUMMY_UNRELATED_ACTIVE_KEY' >"$CHECKOUT/state/certs/active.key"
cp "$CHECKOUT/state/config/global_settings.csv" "$TEST_DIR/settings-before"
cp "$CHECKOUT/state/logs/docker_manager.log" "$TEST_DIR/log-before"
chmod 666 "$CHECKOUT/state/config/global_settings.csv"
chmod 644 "$CHECKOUT/state/logs/docker_manager.log" "$CHECKOUT/state/certs/active.key"
chmod 700 "$CHECKOUT/state" "$CHECKOUT/state/config" "$CHECKOUT/state/logs" "$CHECKOUT/state/certs"
printf '%s\n' 'DUMMY_SELECTED_PRIVATE_KEY' >"$TARGET/private.key"
chmod 644 "$TARGET/private.key"

run_repair || fail_test 'real CLI could not repair an alternate target'
assert_mode "$TARGET/private.key" 600 'selected key'
assert_unrelated_state_unchanged

chmod 644 "$TARGET/private.key"
run_verbose_picker_repair || fail_test 'verbose picker could not repair an alternate target'
assert_mode "$TARGET/private.key" 600 'verbose picker selected key'
assert_unrelated_state_unchanged

# Repair remains usable before normal runtime state has ever been initialized.
rm -rf "$CHECKOUT/state"
chmod 644 "$TARGET/private.key"
run_repair || fail_test 'repair failed with no runtime state'
assert_mode "$TARGET/private.key" 600 'key with no runtime initialization'
[ ! -e "$CHECKOUT/state" ] || fail_test 'repair initialized unrelated runtime state'
[ ! -s "$DOCKER_TRACE" ] || fail_test 'repair without state invoked Docker'

printf 'q\n' | PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
  "$BASH" "$CHECKOUT/dockistrate.sh" -v -i >"$TEST_DIR/output" 2>&1 || fail_test 'verbose picker quit failed'
[ ! -e "$CHECKOUT/state" ] || fail_test 'verbose picker initialized state before selecting a command'
chmod 644 "$TARGET/private.key"
run_verbose_picker_repair || fail_test 'verbose picker repair failed without runtime state'
assert_mode "$TARGET/private.key" 600 'verbose picker key without runtime state'
[ ! -e "$CHECKOUT/state" ] || fail_test 'verbose picker repair initialized unrelated runtime state'
[ ! -s "$DOCKER_TRACE" ] || fail_test 'verbose picker repair invoked Docker'

# A normal command starts verbose logging; a later repair in the same session
# must stop that logging and still deliver errors through the original stderr.
# Also cancel a normal command's argument picker, then run a legacy favorite:
# the inner menus and saved-command review must stop appending to that log.
chmod 644 "$TARGET/private.key"
mkdir -p "$CHECKOUT/state/config"
# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
{
  printf '%s\n' 'command,arg_count,args_csv'
  csv_join_row fix-permissions 1 "$(csv_join_row "$TARGET")"
} >"$CHECKOUT/state/config/interactive_favorites.csv"
chmod 600 "$CHECKOUT/state/config/interactive_favorites.csv"
cp "$CHECKOUT/state/config/interactive_favorites.csv" "$TEST_DIR/favorite-before"
{
  printf '%s\n%s\n%s\n\n' "$advanced_choice" "$runtime_choice" "$visibility_choice"
  # Back keys are single keypresses; newlines here would select the first item
  # in the next menu instead of continuing back toward the home picker.
  printf '%s\n%s\n%s\nqqq' "$advanced_choice" "$runtime_choice" "$cancel_choice"
  printf '%s\n1\n1\n1\n\n' "$favorites_choice"
  repair_picker_input
  repair_picker_input "$TEST_DIR/missing-repair-target"
  printf 'q\n'
} | PATH="$TEST_DIR/bin:$PATH" SKIP_DOCKER_CHECKS=true \
  "$BASH" "$CHECKOUT/dockistrate.sh" -v -i >"$TEST_DIR/output" 2>&1 || fail_test 'normal command followed by repair failed'
assert_mode "$TARGET/private.key" 600 'repair after normal verbose command'
grep -Fq '[CMD]' "$CHECKOUT/state/logs/docker_manager.log" || fail_test 'normal interactive command lost verbose logging'
grep -Eq '\[Error\].*missing-repair-target' "$TEST_DIR/output" || fail_test 'repair error was lost after restoring verbose stderr'
grep -Fq 'Saved command' "$TEST_DIR/output" || fail_test 'cancelled normal command did not reach saved repair review'
cmp -s "$CHECKOUT/state/config/interactive_favorites.csv" "$TEST_DIR/favorite-before" || fail_test 'verbose saved repair changed legacy favorite entry'
if grep -Fq 'Saved command' "$CHECKOUT/state/logs/docker_manager.log"; then
  fail_test 'saved repair review remained logged after cancelling a normal command'
fi
if grep -Fq "$TARGET" "$CHECKOUT/state/logs/docker_manager.log"; then
  fail_test 'later scoped repair leaked into normal-command verbose log'
fi
if grep -Fq 'missing-repair-target' "$CHECKOUT/state/logs/docker_manager.log"; then
  fail_test 'later repair error leaked into normal-command verbose log'
fi
rm -rf "$CHECKOUT/state"
: >"$DOCKER_TRACE"

# Failure must survive CLI dispatch without a success message or bootstrap side
# effects, and a linked inode outside the target must retain its original mode.
printf '%s\n' 'DUMMY_EXTERNAL_KEY' >"$TEST_DIR/external.key"
chmod 644 "$TEST_DIR/external.key"
ln "$TEST_DIR/external.key" "$TARGET/linked.key"
if run_repair; then fail_test 'CLI reported successful repair of a hardlinked key'; fi
if grep -Fq 'Permissions normalization complete' "$TEST_DIR/output"; then
  fail_test 'failed CLI repair printed a completion message'
fi
assert_mode "$TEST_DIR/external.key" 644 'external hardlink target'
[ ! -e "$CHECKOUT/state" ] || fail_test 'failed repair initialized unrelated runtime state'
[ ! -s "$DOCKER_TRACE" ] || fail_test 'failed repair invoked Docker'

printf '[tests] private_key_permissions_cli.sh: PASS\n'
