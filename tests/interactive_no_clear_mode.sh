#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/format_command_display.sh
source "$ROOT_DIR/lib/cli/format_command_display.sh"
# shellcheck source=../lib/cli/choose_option.sh
source "$ROOT_DIR/lib/cli/choose_option.sh"
# shellcheck source=../lib/cli/choose_command_with_filter.sh
source "$ROOT_DIR/lib/cli/choose_command_with_filter.sh"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function command_alias() { printf '%s' "$1"; }
function command_description() { printf '%s' "description"; }

clear_count=0
function clear() {
  clear_count=$((clear_count + 1))
}

idx=""
DOCKISTRATE_NO_CLEAR=true choose_option idx "No clear prompt:" "one" "two" <<<""
if [ "$idx" != "0" ]; then
  echo "[Error] choose_option should still select the first option on Enter under no-clear mode." >&2
  exit 1
fi
if [ "$clear_count" -ne 0 ]; then
  echo "[Error] DOCKISTRATE_NO_CLEAR=true should suppress clear-screen calls." >&2
  exit 1
fi

idx=""
DOCKISTRATE_NO_CLEAR=false choose_option idx "Numeric prompt:" "one" "two" <<<"2"
if [ "$idx" != "1" ]; then
  echo "[Error] choose_option numeric input should select option 2." >&2
  exit 1
fi

idx=""
choose_option idx "Arrow prompt:" "one" "two" < <(printf '\033[B\n')
if [ "$idx" != "1" ]; then
  echo "[Error] choose_option down arrow should select option 2." >&2
  exit 1
fi

idx="kept"
if choose_option idx "Quit prompt:" "one" "two" <<<"q"; then
  echo "[Error] choose_option q should return non-zero." >&2
  exit 1
fi
if [ -n "$idx" ]; then
  echo "[Error] choose_option q should clear the selected index." >&2
  exit 1
fi

idx="kept"
if choose_option idx "Esc prompt:" "one" "two" < <(printf '\033'); then
  echo "[Error] choose_option bare Esc should return non-zero." >&2
  exit 1
fi
if [ -n "$idx" ]; then
  echo "[Error] choose_option bare Esc should clear the selected index." >&2
  exit 1
fi

choice="kept"
# shellcheck disable=SC2034
filter=""
if choose_command_with_filter choice filter "Command prompt:" "status" <<<"q"; then
  echo "[Error] choose_command_with_filter q should return non-zero." >&2
  exit 1
fi
if [ -n "$choice" ]; then
  echo "[Error] choose_command_with_filter q should clear the selected command." >&2
  exit 1
fi

choice="kept"
# shellcheck disable=SC2034
filter=""
if choose_command_with_filter choice filter "Command Esc prompt:" "status" < <(printf '\033'); then
  echo "[Error] choose_command_with_filter bare Esc should return non-zero." >&2
  exit 1
fi
if [ -n "$choice" ]; then
  echo "[Error] choose_command_with_filter bare Esc should clear the selected command." >&2
  exit 1
fi

echo "[tests] interactive_no_clear_mode.sh: PASS"
