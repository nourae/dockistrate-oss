# shellcheck shell=bash

# Populate an array variable with newline-separated values
# Arguments:
#   $1 - name of the array variable to populate
#   $2 - string containing newline-separated values
function read_lines_into_array() {
  local __var_name="$1" input="$2"
  require_valid_var_name "$__var_name" || return 1
  # Ensure callers always receive a defined array, even when input is empty.
  if ! IFS= read -r -a "$__var_name" < <(printf '%s' ""); then
    :
  fi
  if [ "${READ_LINES_INTO_ARRAY_FORCE_FALLBACK:-false}" != "true" ] && command -v mapfile >/dev/null 2>&1; then
    mapfile -t "$__var_name" < <(printf '%s' "$input")
  else
    local __line="" __idx=0
    while IFS= read -r __line || [ -n "$__line" ]; do
      # Bash 3 rejects `printf -v "arr[idx]"` targets as invalid identifiers.
      # Dynamic `read` indexed assignment works with our validated var name.
      IFS= read -r "${__var_name}[${__idx}]" <<<"$__line"
      __idx=$((__idx + 1))
    done < <(printf '%s' "$input")
  fi
}
