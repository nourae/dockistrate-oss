#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper_source="${ROOT_DIR}/sslkeyloglib/sslkeylogfile.c"

fail() {
  echo "[Error] $*" >&2
  exit 1
}

body="$(
  awk '
    /^static void write_sslkeylogfile\(const SSL \*ssl, const char \*line\) \{/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^}/ { exit }
  ' "$helper_source"
)"

[ -n "$body" ] || fail "could not locate write_sslkeylogfile body."

write_count="$(
  printf '%s\n' "$body" |
    awk 'index($0, "write(fd_sslkeylogfile") { count++ } END { print count + 0 }'
)"

if [ "$write_count" != "1" ]; then
  fail "write_sslkeylogfile should use exactly one write(2) call for keylog records; found ${write_count}."
fi

if printf '%s\n' "$body" | grep -Fq 'write(fd_sslkeylogfile, "\n", 1)'; then
  fail "write_sslkeylogfile must not append the newline with a second write(2) call."
fi

if ! printf '%s\n' "$body" | grep -Fq "record[line_len] = '\\n';"; then
  fail "write_sslkeylogfile should append the newline into the single record buffer."
fi

if ! printf '%s\n' "$body" | grep -Fq 'written = write(fd_sslkeylogfile, record, record_len);'; then
  fail "write_sslkeylogfile should write the complete record buffer in one append-mode syscall."
fi

echo "TLS keylog helper single-write guard passed."
