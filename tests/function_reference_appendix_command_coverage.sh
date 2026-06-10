#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_COMMAND_FILE="$ROOT_DIR/lib/cli/run_command.sh"
REFERENCE_MD_FILE="$ROOT_DIR/docs/function-reference.md"
REFERENCE_HTML_FILE="$ROOT_DIR/docs/function-reference.html"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-fnref-cmd-coverage.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

expected_file="$tmp_dir/expected.txt"
md_file="$tmp_dir/md.txt"
html_file="$tmp_dir/html.txt"
md_missing_file="$tmp_dir/md_missing.txt"
md_extra_file="$tmp_dir/md_extra.txt"
html_missing_file="$tmp_dir/html_missing.txt"
html_extra_file="$tmp_dir/html_extra.txt"

for required_file in "$RUN_COMMAND_FILE" "$REFERENCE_MD_FILE" "$REFERENCE_HTML_FILE"; do
  if [[ ! -f "$required_file" ]]; then
    echo "[Error] Required file is missing: $required_file" >&2
    exit 1
  fi
done

awk '
  /^[[:space:]]*[a-z0-9-]+\)/ {
    line = $0
    sub(/^[[:space:]]*/, "", line)
    sub(/\).*/, "", line)
    print line
  }
' "$RUN_COMMAND_FILE" | LC_ALL=C sort -u >"$expected_file"

awk '
  /^## Appendix: Command Call Graphs$/ { in_section = 1; next }
  /^## Appendix: Full Command Call Chains$/ { in_section = 0 }
  in_section && /^- / {
    line = substr($0, 3)
    n = split(line, parts, /`/)
    for (i = 2; i <= n; i += 2) {
      cmd = parts[i]
      if (cmd ~ /^[a-z][a-z0-9-]*$/) {
        print cmd
      }
    }
  }
' "$REFERENCE_MD_FILE" | LC_ALL=C sort -u >"$md_file"

awk '
  /<h2>Appendix: Command Call Graphs<\/h2>/ { in_section = 1; next }
  /<h2>Appendix: Full Command Call Chains<\/h2>/ { in_section = 0 }
  in_section && /<li>/ {
    line = $0
    while (match(line, /<code>[a-z][a-z0-9-]*<\/code>/)) {
      cmd = substr(line, RSTART + 6, RLENGTH - 13)
      print cmd
      line = substr(line, RSTART + RLENGTH)
    }
  }
' "$REFERENCE_HTML_FILE" | LC_ALL=C sort -u >"$html_file"

LC_ALL=C comm -23 "$expected_file" "$md_file" >"$md_missing_file"
LC_ALL=C comm -13 "$expected_file" "$md_file" >"$md_extra_file"
LC_ALL=C comm -23 "$expected_file" "$html_file" >"$html_missing_file"
LC_ALL=C comm -13 "$expected_file" "$html_file" >"$html_extra_file"

failed=0

if [[ -s "$md_missing_file" || -s "$md_extra_file" ]]; then
  echo "[Error] function-reference.md appendix command coverage mismatch." >&2
  if [[ -s "$md_missing_file" ]]; then
    echo "[Error] Missing commands in docs/function-reference.md appendix:" >&2
    sed 's/^/  - /' "$md_missing_file" >&2
  fi
  if [[ -s "$md_extra_file" ]]; then
    echo "[Error] Extra commands in docs/function-reference.md appendix:" >&2
    sed 's/^/  - /' "$md_extra_file" >&2
  fi
  failed=1
fi

if [[ -s "$html_missing_file" || -s "$html_extra_file" ]]; then
  echo "[Error] function-reference.html appendix command coverage mismatch." >&2
  if [[ -s "$html_missing_file" ]]; then
    echo "[Error] Missing commands in docs/function-reference.html appendix:" >&2
    sed 's/^/  - /' "$html_missing_file" >&2
  fi
  if [[ -s "$html_extra_file" ]]; then
    echo "[Error] Extra commands in docs/function-reference.html appendix:" >&2
    sed 's/^/  - /' "$html_extra_file" >&2
  fi
  failed=1
fi

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi

echo "[tests] function_reference_appendix_command_coverage.sh: PASS"
