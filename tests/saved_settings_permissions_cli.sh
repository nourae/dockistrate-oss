#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=lib/saved_settings_fixture.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/saved_settings_fixture.sh"

# shellcheck source=helpers/global_csv.sh
source "$ROOT_DIR/tests/helpers/global_csv.sh"

SETTINGS_CLI_CHECKOUT="$SAVED_SETTINGS_TEST_DIR/checkout"
SETTINGS_CLI_BIN="$SAVED_SETTINGS_TEST_DIR/bin"
mkdir -p "$SETTINGS_CLI_CHECKOUT" "$SETTINGS_CLI_BIN"
cp "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$SETTINGS_CLI_CHECKOUT/"
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$SETTINGS_CLI_CHECKOUT/"
SETTINGS_REAL_CHMOD="$(type -P chmod)"
export SETTINGS_REAL_CHMOD
cat >"$SETTINGS_CLI_BIN/chmod" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${SETTINGS_CLI_CHMOD_FAIL:-}" ] && [ "$arg" = "$SETTINGS_CLI_CHMOD_FAIL" ]; then
    : >"$SETTINGS_CLI_CHMOD_HIT"
    exit 1
  fi
done
exec "$SETTINGS_REAL_CHMOD" "$@"
SHIM
command chmod 700 "$SETTINGS_CLI_BIN/chmod"

# Derive real picker positions from the application's declared menu.
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
settings_advanced="" settings_runtime="" settings_opts=""
for ((settings_idx = 0; settings_idx < ${#INTERACTIVE_PICKER_HOME_OPTIONS[@]}; settings_idx++)); do
  if [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$settings_idx]}" = "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL" ]; then
    settings_advanced=$((settings_idx + 1))
  fi
done
for ((settings_idx = 0; settings_idx < ${#INTERACTIVE_PICKER_CATEGORIES[@]}; settings_idx++)); do
  if [ "${INTERACTIVE_PICKER_CATEGORIES[$settings_idx]}" = 'Global TLS & Runtime' ]; then
    settings_runtime=$((settings_idx + 2))
  fi
done
for ((settings_idx = 0; settings_idx < ${#INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME[@]}; settings_idx++)); do
  if [ "${INTERACTIVE_PICKER_COMMANDS_GLOBAL_TLS_RUNTIME[$settings_idx]}" = set-nginx-docker-opts ]; then
    settings_opts=$((settings_idx + 1))
  fi
done
for settings_choice in "$settings_advanced" "$settings_runtime" "$settings_opts"; do
  [ -n "$settings_choice" ] || saved_settings_fail 'Settings command is missing from the real picker'
done

function settings_cli_reset() {
  saved_settings_reset "cli-$1"
  rm -rf "$SETTINGS_CLI_CHECKOUT/state"
  GLOBAL_SETTINGS_FILE="$SETTINGS_CLI_CHECKOUT/state/config/global_settings.csv"
  CONFIG_DIR="${GLOBAL_SETTINGS_FILE%/*}"
  mkdir -p "$CONFIG_DIR"
  SETTINGS_CLI_CHMOD_FAIL=""
  SETTINGS_CLI_CHMOD_HIT="$BASE_DIR/cli-chmod.hit"
  export SETTINGS_CLI_CHMOD_FAIL SETTINGS_CLI_CHMOD_HIT
}

function settings_cli_run() {
  PATH="$SETTINGS_CLI_BIN:$ROOT_DIR/tests/mocks:$PATH" \
    SKIP_DOCKER_CHECKS=true DOCKER_MOCK_RUNTIME_DIR="$BASE_DIR/docker-mock" \
    "$BASH" "$SETTINGS_CLI_CHECKOUT/dockistrate.sh" "$@" >"$BASE_DIR/output" 2>&1
}

function test_settings_cli_fresh() {
  settings_cli_reset fresh
  umask 000
  settings_cli_run set-nginx-docker-opts '--env SETTINGS_TEST_TOKEN=DUMMY_CLI'
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 640
  grep -Fq 'DUMMY_CLI' "$GLOBAL_SETTINGS_FILE" || saved_settings_fail 'CLI did not save synthetic option'
}

function test_settings_cli_update() {
  settings_cli_reset update
  saved_settings_seed 600
  settings_cli_run set-nginx-docker-opts '--env SETTINGS_TEST_TOKEN=DUMMY_CLI_REPLACEMENT'
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 600
  grep -Fq 'DUMMY_CLI_REPLACEMENT' "$GLOBAL_SETTINGS_FILE" || saved_settings_fail 'CLI update lost options'
  settings_cli_run set-nginx-docker-opts ''
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 600
  [ -z "$(test_global_csv_get "$GLOBAL_SETTINGS_FILE" NGINX_DOCKER_OPTS)" ] || saved_settings_fail 'CLI did not clear saved options'
}

function test_settings_cli_status() {
  local mode="$1"
  settings_cli_reset "status-$mode"
  saved_settings_seed "$mode"
  saved_settings_snapshot
  settings_cli_run status
  saved_settings_assert_original
}

function test_settings_picker() {
  settings_cli_reset picker
  saved_settings_seed 600
  # Existing options expose Keep/Clear/Manual. Finish the multiline value,
  # choose Run, acknowledge completion, then quit the home picker.
  printf '%s\n%s\n%s\n3\n%s\n\n1\n\nq\n' \
    "$settings_advanced" "$settings_runtime" "$settings_opts" \
    '--env SETTINGS_TEST_TOKEN=DUMMY_PICKER' |
    PATH="$SETTINGS_CLI_BIN:$ROOT_DIR/tests/mocks:$PATH" \
      SKIP_DOCKER_CHECKS=true DOCKER_MOCK_RUNTIME_DIR="$BASE_DIR/docker-mock" \
      "$BASH" "$SETTINGS_CLI_CHECKOUT/dockistrate.sh" -i >"$BASE_DIR/output" 2>&1
  saved_settings_assert_mode "$GLOBAL_SETTINGS_FILE" 600
  grep -Fq DUMMY_PICKER "$GLOBAL_SETTINGS_FILE" || {
    cat "$BASE_DIR/output" >&2
    saved_settings_fail 'Real picker did not save synthetic options'
  }
}

function test_settings_cli_protection_failure() {
  settings_cli_reset protection-failure
  saved_settings_seed 666
  saved_settings_snapshot
  SETTINGS_CLI_CHMOD_FAIL="$GLOBAL_SETTINGS_FILE"
  export SETTINGS_CLI_CHMOD_FAIL
  if settings_cli_run set-nginx-docker-opts '--env SETTINGS_TEST_TOKEN=DUMMY_REJECTED'; then
    saved_settings_fail 'CLI ignored failure to protect existing settings'
  fi
  [ -f "$SETTINGS_CLI_CHMOD_HIT" ] || saved_settings_fail 'CLI protection failure was not exercised'
  saved_settings_assert_original
  if grep -Fq 'NGINX_DOCKER_OPTS set and saved' "$BASE_DIR/output"; then
    saved_settings_fail 'Failed CLI operation printed success'
  fi
}

function test_settings_cli_repair() {
  settings_cli_reset repair
  saved_settings_seed 600
  saved_settings_snapshot
  settings_cli_run fix-permissions "$CONFIG_DIR"
  saved_settings_assert_original
}

saved_settings_run_case settings_cli_fresh test_settings_cli_fresh
saved_settings_run_case settings_cli_update_clear_preserves_mode test_settings_cli_update
saved_settings_run_case settings_cli_status_mode_400 test_settings_cli_status 400
saved_settings_run_case settings_cli_status_mode_640 test_settings_cli_status 640
saved_settings_run_case settings_picker_preserves_mode test_settings_picker
saved_settings_run_case settings_cli_protection_failure test_settings_cli_protection_failure
saved_settings_run_case settings_cli_repair_preserves_mode test_settings_cli_repair
saved_settings_finish saved_settings_permissions_cli.sh
