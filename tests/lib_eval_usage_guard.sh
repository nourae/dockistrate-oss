#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-lib-eval-guard.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

lib_files="$tmp_dir/lib_files.txt"
matches_file="$tmp_dir/matches.txt"

if command -v rg >/dev/null 2>&1; then
  rg --files -g '*.sh' lib | LC_ALL=C sort >"$lib_files"
else
  find lib -type f -name '*.sh' | LC_ALL=C sort >"$lib_files"
fi

if [[ ! -s "$lib_files" ]]; then
  echo "[Error] No shell files found under lib/ for eval guard check." >&2
  exit 1
fi

>"$matches_file"
while IFS= read -r rel_path || [[ -n "$rel_path" ]]; do
  [[ -n "$rel_path" ]] || continue

  awk '
    function strip_strings_comments(line,   i, c, out, in_s, in_d, esc) {
      out = ""
      in_s = 0
      in_d = 0
      esc = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (in_s) {
          if (c == "'\''") {
            in_s = 0
          }
          out = out " "
          continue
        }
        if (in_d) {
          if (esc) {
            esc = 0
            out = out " "
            continue
          }
          if (c == "\\") {
            esc = 1
            out = out " "
            continue
          }
          if (c == "\"") {
            in_d = 0
            out = out " "
            continue
          }
          out = out " "
          continue
        }
        if (c == "'\''") {
          in_s = 1
          out = out " "
          continue
        }
        if (c == "\"") {
          in_d = 1
          out = out " "
          continue
        }
        if (c == "#") {
          break
        }
        out = out c
      }
      return out
    }
    {
      clean = strip_strings_comments($0)
      if (clean ~ /(^|[^[:alnum:]_])eval([[:space:];|&(){}]|$)/) {
        print FILENAME ":" FNR ":" $0
      }
    }
  ' "$rel_path" >>"$matches_file"
done <"$lib_files"

if [[ -s "$matches_file" ]]; then
  echo "[Error] Found eval usage in production lib/ modules." >&2
  sed 's/^/  - /' "$matches_file" >&2
  exit 1
fi

echo "[tests] lib_eval_usage_guard.sh: PASS"
