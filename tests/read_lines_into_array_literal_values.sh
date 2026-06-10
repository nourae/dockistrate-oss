#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/cli/read_lines_into_array.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_read_lines.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

marker="${TMP_ROOT}/marker_should_not_exist"
payload="\$(touch ${marker})"
input=$'alpha\n\n'"$payload"$'\n\nomega\n'
empty_input=""

READ_LINES_INTO_ARRAY_FORCE_FALLBACK=true
read_lines_into_array parsed_lines "$input"

if [ -e "$marker" ]; then
  echo "[Error] read_lines_into_array fallback executed payload text." >&2
  exit 1
fi

if [ "${#parsed_lines[@]}" -ne 5 ]; then
  echo "[Error] read_lines_into_array fallback returned unexpected element count." >&2
  exit 1
fi

if [ -n "${parsed_lines[1]}" ] || [ -n "${parsed_lines[3]}" ]; then
  echo "[Error] read_lines_into_array fallback did not preserve empty lines." >&2
  exit 1
fi

if [ "${parsed_lines[2]}" != "$payload" ]; then
  echo "[Error] read_lines_into_array fallback did not preserve literal payload text." >&2
  exit 1
fi

if [ "${parsed_lines[4]}" != "omega" ]; then
  echo "[Error] read_lines_into_array fallback did not preserve trailing line content." >&2
  exit 1
fi

read_lines_into_array empty_lines "$empty_input"
empty_count=0
if ! declare -p empty_lines >/dev/null 2>&1; then
  echo "[Error] read_lines_into_array fallback left empty-input output unset." >&2
  exit 1
fi
empty_count=${#empty_lines[@]}
if [ "$empty_count" -ne 0 ]; then
  echo "[Error] read_lines_into_array fallback returned values for empty input." >&2
  exit 1
fi

if command -v mapfile >/dev/null 2>&1; then
  READ_LINES_INTO_ARRAY_FORCE_FALLBACK=false
  read_lines_into_array mapfile_lines "$input"
  READ_LINES_INTO_ARRAY_FORCE_FALLBACK=true
  read_lines_into_array fallback_lines "$input"

  if [ "${#mapfile_lines[@]}" -ne "${#fallback_lines[@]}" ]; then
    echo "[Error] read_lines_into_array fallback count diverges from mapfile path." >&2
    exit 1
  fi

  for idx in "${!mapfile_lines[@]}"; do
    if [ "${mapfile_lines[$idx]}" != "${fallback_lines[$idx]}" ]; then
      echo "[Error] read_lines_into_array fallback content diverges from mapfile path." >&2
      exit 1
    fi
  done

  READ_LINES_INTO_ARRAY_FORCE_FALLBACK=false
  read_lines_into_array mapfile_empty_lines "$empty_input"
  READ_LINES_INTO_ARRAY_FORCE_FALLBACK=true
  read_lines_into_array fallback_empty_lines "$empty_input"

  if ! declare -p mapfile_empty_lines >/dev/null 2>&1; then
    echo "[Error] read_lines_into_array mapfile path left empty-input output unset." >&2
    exit 1
  fi
  if ! declare -p fallback_empty_lines >/dev/null 2>&1; then
    echo "[Error] read_lines_into_array fallback path left empty-input output unset during parity check." >&2
    exit 1
  fi

  mapfile_empty_count=0
  fallback_empty_count=0
  mapfile_empty_count=${#mapfile_empty_lines[@]}
  fallback_empty_count=${#fallback_empty_lines[@]}
  if [ "$mapfile_empty_count" -ne "$fallback_empty_count" ]; then
    echo "[Error] read_lines_into_array empty-input behavior diverges from mapfile path." >&2
    exit 1
  fi
fi

echo "read_lines_into_array fallback literal-value checks passed."
