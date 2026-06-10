#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_COMMAND_FILE="$ROOT_DIR/lib/cli/run_command.sh"
COMPLETION_FILE="$ROOT_DIR/completion/dockistrate-completion.bash"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-completion-coverage.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

dispatch_file="$tmp_dir/dispatch.txt"
completion_file="$tmp_dir/completion.txt"
missing_file="$tmp_dir/missing.txt"
extra_file="$tmp_dir/extra.txt"

awk '
  /^[[:space:]]*[a-z0-9-]+\)/ {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/\).*/, "", line)
    print line
  }
' "$RUN_COMMAND_FILE" | LC_ALL=C sort -u >"$dispatch_file"

awk '
  /local commands="/ {
    line = $0
    sub(/^.*local commands="/, "", line)
    sub(/".*$/, "", line)
    n = split(line, commands, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (commands[i] != "") {
        print commands[i]
      }
    }
  }
' "$COMPLETION_FILE" | LC_ALL=C sort -u >"$completion_file"

LC_ALL=C comm -23 "$dispatch_file" "$completion_file" >"$missing_file"
LC_ALL=C comm -13 "$dispatch_file" "$completion_file" >"$extra_file"

if [ -s "$missing_file" ] || [ -s "$extra_file" ]; then
  echo "[Error] Bash completion command list differs from CLI dispatch." >&2
  if [ -s "$missing_file" ]; then
    echo "[Error] Missing from completion:" >&2
    sed 's/^/  - /' "$missing_file" >&2
  fi
  if [ -s "$extra_file" ]; then
    echo "[Error] Extra in completion:" >&2
    sed 's/^/  - /' "$extra_file" >&2
  fi
  exit 1
fi

echo "[tests] completion_command_coverage.sh: PASS"
