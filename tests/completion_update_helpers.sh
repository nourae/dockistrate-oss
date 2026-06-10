#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

__dockistrate_completion_dir="$ROOT_DIR/completion"
__dockistrate_completion_handlers=()
COMPREPLY=()

# shellcheck source=../completion/commands/_dockistrate_complete_misc.sh
source "$ROOT_DIR/completion/commands/_dockistrate_complete_misc.sh"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

cur=""
cword=2
COMPREPLY=()
_dockistrate_complete_misc help || fail_test "help completion handler should handle help"
[ "${#COMPREPLY[@]}" -eq 1 ] && [ "${COMPREPLY[0]}" = "update" ] ||
  fail_test "help completion should suggest update as the first topic"

cur=""
cword=3
COMPREPLY=("stale")
_dockistrate_complete_misc help || fail_test "help completion handler should handle help after topic"
[ "${#COMPREPLY[@]}" -eq 0 ] ||
  fail_test "help completion should not suggest another topic after help update"

echo "[tests] completion_update_helpers.sh: PASS"
