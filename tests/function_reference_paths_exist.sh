#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFERENCE_FILE="$ROOT_DIR/docs/function-reference.md"

line_no=0
missing=0

while IFS= read -r line; do
  line_no=$((line_no + 1))

  if [[ "$line" == "### "* && "$line" == *" (\`"*"\`)" ]]; then
    raw_paths="${line#* (\`}"
    raw_paths="${raw_paths%\`)}"

    IFS=',' read -r -a paths <<< "$raw_paths"
    for path in "${paths[@]}"; do
      trimmed="${path#"${path%%[![:space:]]*}"}"
      trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
      [[ -z "$trimmed" ]] && continue

      if [[ ! -e "$ROOT_DIR/$trimmed" ]]; then
        echo "[tests] function-reference missing path: $trimmed (line $line_no)"
        missing=1
      fi
    done
  fi
done < "$REFERENCE_FILE"

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "[tests] function-reference path check passed"
