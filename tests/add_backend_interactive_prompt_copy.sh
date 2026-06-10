#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target_file="${ROOT_DIR}/lib/cli/collect_add_backend_interactive.sh"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

for forbidden in \
  "blank=menu" \
  "blank or Back returns to menu" \
  "[Y/n]" \
  "[y/N]"; do
  if grep -Fq "$forbidden" "$target_file"; then
    fail_test "add-backend interactive prompt copy still contains misleading text: ${forbidden}"
  fi
done

for expected in \
  "Domain:" \
  "Domain is required" \
  "HTTP->HTTPS redirect:" \
  "Enable redirect" \
  "Do not redirect" \
  "WebSocket support:" \
  "Disabled" \
  "Enabled" \
  "Expose port now:" \
  "Expose now" \
  "Do not expose"; do
  if ! grep -Fq "$expected" "$target_file"; then
    fail_test "add-backend interactive prompt copy missing expected text: ${expected}"
  fi
done

echo "[tests] add_backend_interactive_prompt_copy.sh: PASS"
