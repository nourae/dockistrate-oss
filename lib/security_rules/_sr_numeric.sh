# shellcheck shell=bash

function _sr_is_unsigned_int() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}


function _sr_trim_leading_zeros() {
  local v="${1:-0}"
  while [[ "${#v}" -gt 1 && "${v:0:1}" == "0" ]]; do
    v="${v:1}"
  done
  printf '%s' "$v"
}


function _sr_numeric_inc() {
  local num="$1"
  local carry=1 digit i res=""
  for ((i = ${#num} - 1; i >= 0; i--)); do
    digit=$((${num:i:1} + carry))
    if ((digit >= 10)); then
      digit=$((digit - 10))
      carry=1
    else
      carry=0
    fi
    res="${digit}${res}"
  done
  if ((carry)); then
    res="1${res}"
  fi
  printf '%s' "$res"
}


function _sr_numeric_regex_ge_same() {
  local digits="$1" len=${#1}
  if ((len == 0)); then
    printf ''
    return
  fi
  local first=${digits:0:1}
  if ((len == 1)); then
    if ((first >= 9)); then
      printf '%s' "$first"
    else
      printf '[%d-9]' "$first"
    fi
    return
  fi
  local rest="${digits:1}" parts=() joined="" idx next tail rest_len=$((len - 1))
  if ((first < 9)); then
    next=$((first + 1))
    parts+=("[${next}-9][0-9]{${rest_len}}")
  fi
  tail="$(_sr_numeric_regex_ge_same "$rest")"
  if [ -n "$tail" ]; then
    parts+=("${first}${tail}")
  else
    parts+=("${first}[0-9]{${rest_len}}")
  fi
  if ((${#parts[@]} == 0)); then
    printf ''
    return
  fi
  joined="${parts[0]}"
  for ((idx = 1; idx < ${#parts[@]}; idx++)); do
    joined+="|${parts[$idx]}"
  done
  if ((${#parts[@]} > 1)); then
    printf '(?:%s)' "$joined"
  else
    printf '%s' "$joined"
  fi
}


function _sr_numeric_regex_ge() {
  local raw="$(_sr_trim_leading_zeros "${1:-0}")"
  if [ -z "$raw" ]; then raw="0"; fi
  if [ "$raw" = "0" ]; then
    printf '[0-9]+'
    return
  fi
  local len=${#raw} parts=() joined="" idx same
  parts+=("[1-9][0-9]{${len},}")
  same="$(_sr_numeric_regex_ge_same "$raw")"
  if [ -n "$same" ]; then
    parts+=("${same}")
  fi
  joined="${parts[0]}"
  for ((idx = 1; idx < ${#parts[@]}; idx++)); do
    joined+="|${parts[$idx]}"
  done
  if ((${#parts[@]} > 1)); then
    printf '(?:%s)' "$joined"
  else
    printf '%s' "$joined"
  fi
}


function _sr_numeric_regex_lt_same() {
  local digits="$1" len=${#1}
  if ((len == 0)); then
    printf ''
    return
  fi

  local first=${digits:0:1}
  if ((len == 1)); then
    if ((first <= 0)); then
      printf ''
    else
      printf '[0-%d]' "$((first - 1))"
    fi
    return
  fi

  local rest="${digits:1}" parts=() joined="" idx tail rest_len=$((len - 1))
  if ((first > 0)); then
    parts+=("[0-$((first - 1))][0-9]{${rest_len}}")
  fi

  tail="$(_sr_numeric_regex_lt_same "$rest")"
  if [ -n "$tail" ]; then
    parts+=("${first}${tail}")
  fi

  if ((${#parts[@]} == 0)); then
    printf ''
    return
  fi

  joined="${parts[0]}"
  for ((idx = 1; idx < ${#parts[@]}; idx++)); do
    joined+="|${parts[$idx]}"
  done
  if ((${#parts[@]} > 1)); then
    printf '(?:%s)' "$joined"
  else
    printf '%s' "$joined"
  fi
}


function _sr_numeric_regex_lt() {
  local raw="$(_sr_trim_leading_zeros "${1:-0}")"
  if [ -z "$raw" ]; then raw="0"; fi
  if [ "$raw" = "0" ]; then
    printf '(?!)'
    return
  fi

  local len=${#raw} parts=() joined="" idx same
  if ((len > 1)); then
    parts+=("[0-9]{1,$((len - 1))}")
  fi

  same="$(_sr_numeric_regex_lt_same "$raw")"
  if [ -n "$same" ]; then
    parts+=("${same}")
  fi

  joined="${parts[0]}"
  for ((idx = 1; idx < ${#parts[@]}; idx++)); do
    joined+="|${parts[$idx]}"
  done
  if ((${#parts[@]} > 1)); then
    printf '(?:%s)' "$joined"
  else
    printf '%s' "$joined"
  fi
}


function _sr_numeric_regex_le() {
  _sr_numeric_regex_lt "$(_sr_numeric_inc "$1")"
}

# Map condition to Nginx predicates
