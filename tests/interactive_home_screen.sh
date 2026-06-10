#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/interactive_dashboard.sh
source "$ROOT_DIR/lib/cli/interactive_dashboard.sh"
# shellcheck source=../lib/cli/interactive_picker.sh
source "$ROOT_DIR/lib/cli/interactive_picker.sh"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function clear() { :; }
function cli_read_keypress() {
  local __out_var="${1:-}"
  printf -v "$__out_var" '%s' ""
  return 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-home-screen.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

CONFIG_DIR="${tmp_dir}/config"
CERTS_DIR="${tmp_dir}/certs"
BACKUP_DIR="${tmp_dir}/backups"
BACKEND_PORTS_FILE="${CONFIG_DIR}/backend_ports.csv"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$BACKUP_DIR"

function docker() {
  return 127
}

PROMPT_ARGS_SHOULD_NOT_RUN=true
PROMPT_ARGS_CMD=""
function prompt_args_for_command() {
  if [ "${PROMPT_ARGS_SHOULD_NOT_RUN:-false}" = true ]; then
    echo "[Error] prompt_args_for_command should not be called while rendering the home screen." >&2
    exit 1
  fi

  PROMPT_ARGS_CMD="${1:-}"
  SELECTED_CMD="${1:-}"
  SELECTED_ARGS=()
  return 0
}

for fn in \
  interactive_picker \
  interactive_command_browser \
  interactive_picker_search_all_commands \
  interactive_picker_run_home_action \
  interactive_picker_choose_command_list \
  interactive_picker_run_command_prompt; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "[Error] Missing expected interactive picker function: ${fn}." >&2
    exit 1
  fi
done

output_file="${tmp_dir}/home.out"
if interactive_picker >"$output_file"; then
  echo "[Error] EOF from the home screen should return non-zero." >&2
  exit 1
fi

for expected in \
  "What do you want to do?" \
  "Proxy:" \
  "Backends:" \
  "Ports:" \
  "Certificates:" \
  "Backups:" \
  "Capture:" \
  "Add a new backend" \
  "Recent commands" \
  "Favorites" \
  "Expose or update a port" \
  "Start / stop services" \
  "Certificates" \
  "Access control & security rules" \
  "Updates / release preflight" \
  "Diagnostics / troubleshoot" \
  "Search all commands" \
  "Advanced command browser" \
  "Quit"; do
  if ! grep -Fq "$expected" "$output_file"; then
    echo "[Error] Home screen output missing expected text: ${expected}." >&2
    exit 1
  fi
done

PROMPT_ARGS_SHOULD_NOT_RUN=false
if ! interactive_picker_run_home_action "$INTERACTIVE_PICKER_HOME_ADD_BACKEND_LABEL"; then
  echo "[Error] Add backend home action should route to the add-backend prompt." >&2
  exit 1
fi
if [ "$PROMPT_ARGS_CMD" != "add-backend" ]; then
  echo "[Error] Add backend home action routed to '${PROMPT_ARGS_CMD}', expected add-backend." >&2
  exit 1
fi

HOME_LIST_PROMPT=""
HOME_LIST_COMMANDS=()
function interactive_picker_choose_command_list() {
  HOME_LIST_PROMPT="${1:-}"
  shift || true
  HOME_LIST_COMMANDS=("$@")
  return 0
}

if ! interactive_picker_run_home_action "$INTERACTIVE_PICKER_HOME_UPDATES_LABEL"; then
  echo "[Error] Updates home action should route to the update command list." >&2
  exit 1
fi
if [ "$HOME_LIST_PROMPT" != "${INTERACTIVE_PICKER_HOME_UPDATES_LABEL}:" ]; then
  echo "[Error] Updates home action prompt mismatch: '${HOME_LIST_PROMPT}'." >&2
  exit 1
fi
if [ "${#HOME_LIST_COMMANDS[@]}" -ne 2 ] ||
  [ "${HOME_LIST_COMMANDS[0]}" != "help-update" ] ||
  [ "${HOME_LIST_COMMANDS[1]}" != "upgrade-preflight" ]; then
  echo "[Error] Updates home action should expose help-update and upgrade-preflight." >&2
  exit 1
fi

CHOICE_QUEUE=()
CHOICE_CURSOR=0
CHOICE_PROMPTS=()
CHOICE_LAST_OPTIONS=()
function reset_choice_queue() {
  CHOICE_QUEUE=("$@")
  CHOICE_CURSOR=0
  CHOICE_PROMPTS=()
  CHOICE_LAST_OPTIONS=()
}

function choose_option() {
  local __idx_var="${1:-}" prompt="${2:-}"
  shift 2
  CHOICE_PROMPTS+=("$prompt")
  CHOICE_LAST_OPTIONS=("$@")
  if [ "$CHOICE_CURSOR" -ge "${#CHOICE_QUEUE[@]}" ]; then
    echo "[Error] choose_option queue exhausted." >&2
    exit 1
  fi
  if [ "${CHOICE_QUEUE[$CHOICE_CURSOR]}" = "__FAIL__" ]; then
    CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
    printf -v "$__idx_var" '%s' ""
    return 1
  fi
  printf -v "$__idx_var" '%s' "${CHOICE_QUEUE[$CHOICE_CURSOR]}"
  CHOICE_CURSOR=$((CHOICE_CURSOR + 1))
  return 0
}

browser_category_count=$((1 + ${#INTERACTIVE_PICKER_CATEGORIES[@]}))
browser_back_idx="$browser_category_count"
browser_quit_idx=$((browser_category_count + 1))

reset_choice_queue "$browser_back_idx"
set +e
interactive_command_browser home >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ]; then
  echo "[Error] Back to home from advanced browser should return status 1 to the home loop." >&2
  exit 1
fi
if [[ " ${CHOICE_LAST_OPTIONS[*]} " != *" Back to home "* ]] || [[ " ${CHOICE_LAST_OPTIONS[*]} " != *" Quit "* ]]; then
  echo "[Error] Home-launched advanced browser should show Back to home and Quit." >&2
  exit 1
fi

reset_choice_queue "$browser_quit_idx"
set +e
interactive_command_browser home >/dev/null
status=$?
set -e
if [ "$status" -ne 2 ]; then
  echo "[Error] Quit from home-launched advanced browser should return status 2." >&2
  exit 1
fi

reset_choice_queue "__FAIL__"
set +e
interactive_command_browser home >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ]; then
  echo "[Error] Esc/Q-style failure from home-launched advanced browser should return to home." >&2
  exit 1
fi

reset_choice_queue "$browser_category_count"
set +e
interactive_command_browser >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ]; then
  echo "[Error] Direct advanced browser Quit should preserve top-level exit behavior." >&2
  exit 1
fi
if [[ " ${CHOICE_LAST_OPTIONS[*]} " == *" Back to home "* ]]; then
  echo "[Error] Direct advanced browser should not show Back to home." >&2
  exit 1
fi

advanced_idx=""
for idx in "${!INTERACTIVE_PICKER_HOME_OPTIONS[@]}"; do
  if [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$idx]}" = "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL" ]; then
    advanced_idx="$idx"
    break
  fi
done
if [ -z "$advanced_idx" ]; then
  echo "[Error] Advanced command browser home option not found." >&2
  exit 1
fi
home_quit_idx="${#INTERACTIVE_PICKER_HOME_OPTIONS[@]}"
reset_choice_queue "$advanced_idx" "$browser_back_idx" "$home_quit_idx"
set +e
interactive_picker >/dev/null
status=$?
set -e
if [ "$status" -ne 1 ] || [ "$CHOICE_CURSOR" -ne 3 ]; then
  echo "[Error] Advanced browser Back should return to the home menu before final Quit." >&2
  exit 1
fi

echo "[tests] interactive_home_screen.sh: PASS"
