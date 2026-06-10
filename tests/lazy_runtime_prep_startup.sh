#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.lazy-startup.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

TIMEOUT_HELPER="${ROOT_DIR}/tests/lib/run_with_timeout.sh"
STATE_DIR="${ROOT_DIR}/state"
MOCK_BIN="${WORK_DIR}/mock-bin"
DOCKER_TOUCH_FILE="${WORK_DIR}/docker_called"
mkdir -p "$MOCK_BIN"

if ! "$TIMEOUT_HELPER" --probe >/dev/null 2>&1; then
  echo "[Skip] GNU timeout/gtimeout not installed; skipping lazy runtime timeout checks."
  exit 0
fi

cat >"${MOCK_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${DOCKER_TOUCH_FILE:?}"
touch "$DOCKER_TOUCH_FILE"
exit 1
EOF
chmod +x "${MOCK_BIN}/docker"

interactive_runner="${WORK_DIR}/run_interactive.sh"
cat >"${interactive_runner}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$1"
INPUT_FILE="$2"
OUTPUT_FILE="$3"
ERROR_FILE="$4"
MOCK_BIN="$5"
DOCKER_TOUCH_FILE="$6"

(
  export PATH="${MOCK_BIN}:$PATH"
  export DOCKER_TOUCH_FILE
  cd "$ROOT_DIR"
  ./dockistrate.sh -i <"$INPUT_FILE" >"$OUTPUT_FILE" 2>"$ERROR_FILE"
)
EOF
chmod +x "${interactive_runner}"

run_interactive_case() {
  local label="$1" input_file="$2" output_file="$3" error_file="$4"
  "$TIMEOUT_HELPER" 10 2 "$label" -- \
    "$interactive_runner" \
    "$ROOT_DIR" \
    "$input_file" \
    "$output_file" \
    "$error_file" \
    "$MOCK_BIN" \
    "$DOCKER_TOUCH_FILE"
}

usage_out="${WORK_DIR}/usage.out"
usage_err="${WORK_DIR}/usage.err"
if (cd "$ROOT_DIR" && PATH="${MOCK_BIN}:$PATH" DOCKER_TOUCH_FILE="$DOCKER_TOUCH_FILE" ./dockistrate.sh >"$usage_out" 2>"$usage_err"); then
  echo "[Error] Expected dockistrate.sh without command to exit non-zero." >&2
  exit 1
fi
if [ -f "$DOCKER_TOUCH_FILE" ]; then
  echo "[Error] Startup usage path should not execute docker." >&2
  exit 1
fi

interactive_out="${WORK_DIR}/interactive.out"
interactive_err="${WORK_DIR}/interactive.err"
interactive_input_file="${WORK_DIR}/interactive.input"
interactive_eof_out="${WORK_DIR}/interactive_eof.out"
interactive_eof_err="${WORK_DIR}/interactive_eof.err"
interactive_eof_input_file="${WORK_DIR}/interactive_eof.input"
interactive_home_advanced_index=8
interactive_quit_index=19
interactive_basic_index=2
interactive_back_index=1
menu_data_file="${ROOT_DIR}/lib/cli/interactive_picker_menu_data.sh"
if [ -f "$menu_data_file" ]; then
  # shellcheck disable=SC1090
  source "$menu_data_file"
  if declare -p INTERACTIVE_PICKER_HOME_OPTIONS >/dev/null 2>&1; then
    interactive_advanced_label="${INTERACTIVE_PICKER_HOME_ADVANCED_LABEL:-Advanced command browser}"
    for idx in "${!INTERACTIVE_PICKER_HOME_OPTIONS[@]}"; do
      if [ "${INTERACTIVE_PICKER_HOME_OPTIONS[$idx]}" = "$interactive_advanced_label" ]; then
        interactive_home_advanced_index=$((idx + 1))
        break
      fi
    done
  fi
  if declare -p INTERACTIVE_PICKER_CATEGORIES >/dev/null 2>&1; then
    interactive_basic_index=2
    interactive_quit_index=$((${#INTERACTIVE_PICKER_CATEGORIES[@]} + 2))
  fi
  if declare -p INTERACTIVE_PICKER_COMMANDS_BASIC >/dev/null 2>&1; then
    interactive_back_index=$((${#INTERACTIVE_PICKER_COMMANDS_BASIC[@]} + 1))
  fi
fi

interactive_input="${interactive_home_advanced_index}"
interactive_input+=$'\n'
interactive_input+="${interactive_basic_index}"
interactive_input+=$'\n'
interactive_input+="${interactive_back_index}"
interactive_input+=$'\n'
interactive_input+="${interactive_quit_index}"
interactive_input+=$'\n'
printf '%b' "$interactive_input" >"$interactive_input_file"
: >"$interactive_eof_input_file"

if ! run_interactive_case "interactive back/quit" "$interactive_input_file" "$interactive_out" "$interactive_err"; then
  echo "[Error] Expected interactive picker back/quit path to exit successfully." >&2
  exit 1
fi
if [ -f "$DOCKER_TOUCH_FILE" ]; then
  echo "[Error] Interactive back/quit path should not execute docker." >&2
  exit 1
fi

rm -f "$DOCKER_TOUCH_FILE"
if ! run_interactive_case "interactive EOF exit" "$interactive_eof_input_file" "$interactive_eof_out" "$interactive_eof_err"; then
  echo "[Error] Expected interactive EOF path to exit successfully." >&2
  exit 1
fi
if [ -f "$DOCKER_TOUCH_FILE" ]; then
  echo "[Error] Interactive EOF path should not execute docker." >&2
  exit 1
fi

status_out="${WORK_DIR}/status.out"
status_err="${WORK_DIR}/status.err"
if (cd "$ROOT_DIR" && PATH="${MOCK_BIN}:$PATH" DOCKER_TOUCH_FILE="$DOCKER_TOUCH_FILE" SKIP_DOCKER_CHECKS=false ./dockistrate.sh status >"$status_out" 2>"$status_err"); then
  echo "[Error] Expected status command to fail with mocked docker error." >&2
  exit 1
fi
if [ ! -f "$DOCKER_TOUCH_FILE" ]; then
  echo "[Error] Command execution path should run deferred dependency checks (docker should be called)." >&2
  exit 1
fi

echo "Lazy runtime startup/dependency deferral checks passed."
