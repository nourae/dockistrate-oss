#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/cli/mark_current_option.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_mark_current.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

marker="${TMP_ROOT}/marker_should_not_exist"
payload="\$(touch ${marker})"

function run_mark_current_case() {
  local -a _vals=("alpha" "$payload" "omega")
  local -a _disp=("alpha" "$payload" "omega")
  mark_current_option "$payload"
  RESULT_VALS=("${_vals[@]}")
  RESULT_DISP=("${_disp[@]}")
}

function run_mark_current_empty_arrays_case() {
  local -a _vals=()
  local -a _disp=()
  mark_current_option "alpha"
  if [ "${#_vals[@]}" -ne 0 ] || [ "${#_disp[@]}" -ne 0 ]; then
    return 1
  fi
}

function run_mark_current_unset_arrays_case() {
  unset _vals _disp
  mark_current_option "alpha"
}

RESULT_VALS=()
RESULT_DISP=()
run_mark_current_case

if [ -e "$marker" ]; then
  echo "[Error] mark_current_option executed payload while marking defaults." >&2
  exit 1
fi

if [ "${RESULT_VALS[1]}" != "$payload" ]; then
  echo "[Error] mark_current_option modified option values unexpectedly." >&2
  exit 1
fi

if [ "${RESULT_DISP[1]}" != "${payload} (current)" ]; then
  echo "[Error] mark_current_option did not mark current option correctly." >&2
  exit 1
fi

if ! run_mark_current_empty_arrays_case; then
  echo "[Error] mark_current_option failed when _vals/_disp are empty arrays under set -u." >&2
  exit 1
fi

if ! run_mark_current_unset_arrays_case; then
  echo "[Error] mark_current_option failed when _vals/_disp are unset under set -u." >&2
  exit 1
fi

echo "mark_current_option literal-value checks passed."
