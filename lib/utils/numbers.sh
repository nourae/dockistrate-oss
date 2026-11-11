# shellcheck shell=bash

# Validate before using shell arithmetic: digit strings with a leading zero
# otherwise select octal, and an oversized decimal value can wrap around.
# The default ceiling fits Bash 3's signed integer arithmetic. Callers that
# add to the result must use a smaller bound (or a known row/port count).
function normalize_decimal_number() {
  local number="${1:-}" maximum="${2:-9223372036854775807}" LC_ALL=C
  [[ "$number" =~ ^[0-9]+$ ]] || return 1
  while [ "${#number}" -gt 1 ] && [ "${number#0}" != "$number" ]; do number="${number#0}"; done
  [ "${#number}" -le "${#maximum}" ] || return 1
  if [ "${#number}" -eq "${#maximum}" ] && [[ "$number" > "$maximum" ]]; then return 1; fi
  printf '%s' "$number"
}

function normalize_positive_decimal() {
  [[ "${1:-}" =~ [1-9] ]] || return 1
  normalize_decimal_number "${1:-}" "${2:-9223372036854775807}"
}

function normalize_port() {
  normalize_positive_decimal "${1:-}" 65535
}
