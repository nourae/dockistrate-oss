#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_FILE="$ROOT_DIR/dockistrate.sh"

if [[ ! -f "$TARGET_FILE" ]]; then
  echo "[Error] Missing dockistrate.sh at $TARGET_FILE" >&2
  exit 1
fi

if ! grep -Eq '\[ "\$\{SELECTED_CMD:-\}" != "status" \] && \[ "\$\{SELECTED_CMD:-\}" != "status-all" \]' "$TARGET_FILE"; then
  echo "[Error] Interactive post-command pause should exempt both status and status-all." >&2
  exit 1
fi

if ! grep -Eq 'function dockistrate_run_selected_command\(\)' "$TARGET_FILE"; then
  echo "[Error] Interactive selected-command execution should be isolated in a helper." >&2
  exit 1
fi

if ! grep -Eq 'if ! dockistrate_run_selected_command; then' "$TARGET_FILE"; then
  echo "[Error] Interactive picker should guard selected-command failures so set -e does not exit the session." >&2
  exit 1
fi

echo "interactive status screen pause guard passed."
