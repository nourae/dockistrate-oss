# shellcheck shell=bash

function _sr_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//|/\\|}"
  printf '%s\n' "$s"
}


function _sr_unescape() {
  local s="${1:-}"
  s="${s//\\|/|}"
  s="${s//\\\\/\\}"
  printf '%s\n' "$s"
}


function _sr_escape_regex_literal() {
  local s="${1:-}" out="" i char
  for ((i = 0; i < ${#s}; i++)); do
    char="${s:i:1}"
    case "$char" in
    '\\' | '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '{' | '}' | '/')
      out+="\\${char}"
      ;;
    '[')
      out+="\\["
      ;;
    ']')
      out+="\\]"
      ;;
    '|')
      out+="\\|"
      ;;
    *)
      out+="$char"
      ;;
    esac
  done
  printf '%s' "$out"
}


function _escape_nginx_value() {
  local v="${1:-}"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s\n' "$v"
}


function condition_alias() {
  local _c="$1"
  _c="${_c//_/ }"
  echo "$_c" | awk '{for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1))tolower(substr($i,2)) }}1'
}

# Escape/Unescape rule fragments used in expression building.
