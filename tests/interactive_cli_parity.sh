#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-parity.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cli_cmds_file="${tmp_dir}/cli_cmds.txt"
interactive_cmds_file="${tmp_dir}/interactive_cmds.txt"
cli_only_file="${tmp_dir}/cli_only.txt"
interactive_only_file="${tmp_dir}/interactive_only.txt"

awk '
  /^[[:space:]]*[a-z0-9-]+\)/ {
    line=$0
    sub(/^[[:space:]]*/, "", line)
    sub(/\).*/, "", line)
    print line
  }
' lib/cli/run_command.sh | grep -vx 'help' | sort -u >"$cli_cmds_file"

awk '
  /^INTERACTIVE_PICKER_COMMANDS_[A-Z0-9_]+=\(/ { in_arr=1; next }
  in_arr && /^\)/ { in_arr=0; next }
  in_arr {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^[a-z][a-z0-9-]*$/) {
        print $i
      }
    }
  }
' lib/cli/interactive_picker_menu_data.sh | sort -u >"$interactive_cmds_file"

comm -23 "$cli_cmds_file" "$interactive_cmds_file" >"$cli_only_file"
comm -13 "$cli_cmds_file" "$interactive_cmds_file" >"$interactive_only_file"

if [ -s "$cli_only_file" ] || [ -s "$interactive_only_file" ]; then
  echo "[Error] interactive/CLI command parity mismatch detected." >&2
  if [ -s "$cli_only_file" ]; then
    echo "[Error] CLI-only commands missing from interactive picker:" >&2
    sed 's/^/  - /' "$cli_only_file" >&2
  fi
  if [ -s "$interactive_only_file" ]; then
    echo "[Error] Interactive-only commands missing from CLI dispatch:" >&2
    sed 's/^/  - /' "$interactive_only_file" >&2
  fi
  exit 1
fi

echo "[tests] interactive_cli_parity.sh: PASS"
