# shellcheck shell=bash
function _docker_opts_should_preserve_literal_quote() {
  local token="${1:-}" value_part=""
  [ -n "$token" ] || return 1

  case "$token" in
  *=*)
    value_part="${token#*=}"
    case "$value_part" in
    \[* | \{*)
      return 0
      ;;
    esac
    ;;
  esac

  return 1
}

function _parse_docker_opts_to_lines() {
  local raw_opts="$1"
  local context="${2:-docker options}"

  if [ -z "$raw_opts" ]; then
    return 0
  fi

  local mode="unquoted"
  local escape_next=0
  local token=""
  local token_started=0
  local -a tokens=()
  local length="${#raw_opts}"
  local i=0

  while [ "$i" -lt "$length" ]; do
    local char="${raw_opts:i:1}"

    if [ "$mode" = "single" ]; then
      if [ "$char" = "'" ]; then
        mode="unquoted"
      else
        token+="$char"
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$mode" = "literal_single" ]; then
      token+="$char"
      token_started=1
      if [ "$char" = "'" ]; then
        mode="unquoted"
      elif [ "$char" = "\\" ]; then
        escape_next=1
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$escape_next" -eq 1 ]; then
      token+="$char"
      token_started=1
      escape_next=0
      i=$((i + 1))
      continue
    fi

    if [ "$mode" = "double" ]; then
      if [ "$char" = '"' ]; then
        mode="unquoted"
        i=$((i + 1))
        continue
      fi

      if [ "$char" = "\\" ]; then
        local next_char=""
        if [ $((i + 1)) -lt "$length" ]; then
          next_char="${raw_opts:i+1:1}"
        fi

        if [ "$next_char" = $'\n' ]; then
          i=$((i + 2))
          continue
        fi

        if [ "$next_char" = $'\r' ]; then
          if [ $((i + 2)) -lt "$length" ] && [ "${raw_opts:i+2:1}" = $'\n' ]; then
            i=$((i + 3))
          else
            i=$((i + 2))
          fi
          continue
        fi

        if [ "$next_char" = '$' ] || [ "$next_char" = '`' ] || [ "$next_char" = '"' ] || [ "$next_char" = "\\" ]; then
          escape_next=1
          i=$((i + 1))
          continue
        fi

        token+="\\"
        token_started=1
        i=$((i + 1))
        continue
      fi

      token+="$char"
      token_started=1
      i=$((i + 1))
      continue
    fi

    if [ "$mode" = "literal_double" ]; then
      token+="$char"
      token_started=1
      if [ "$char" = '"' ]; then
        mode="unquoted"
      elif [ "$char" = "\\" ]; then
        escape_next=1
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$char" = "'" ]; then
      if [ "$token_started" -eq 1 ] && _docker_opts_should_preserve_literal_quote "$token"; then
        token+="$char"
        mode="literal_single"
      else
        mode="single"
      fi
      token_started=1
    elif [ "$char" = '"' ]; then
      if [ "$token_started" -eq 1 ] && _docker_opts_should_preserve_literal_quote "$token"; then
        token+="$char"
        mode="literal_double"
      else
        mode="double"
      fi
      token_started=1
    elif [ "$char" = "\\" ]; then
      local next_char=""
      if [ $((i + 1)) -lt "$length" ]; then
        next_char="${raw_opts:i+1:1}"
      fi

      # Support docs-style multi-line input:
      #   --flag value \
      #   --next ...
      if [ "$next_char" = $'\n' ]; then
        i=$((i + 2))
        continue
      fi

      if [ "$next_char" = $'\r' ]; then
        if [ $((i + 2)) -lt "$length" ] && [ "${raw_opts:i+2:1}" = $'\n' ]; then
          i=$((i + 3))
        else
          i=$((i + 2))
        fi
        continue
      fi

      escape_next=1
    elif [ "$char" = ' ' ] || [ "$char" = $'\t' ] || [ "$char" = $'\n' ] || [ "$char" = $'\r' ]; then
      if [ "$token_started" -eq 1 ]; then
        tokens+=("$token")
        token=""
        token_started=0
      fi
    else
      token+="$char"
      token_started=1
    fi

    i=$((i + 1))
  done

  if [ "$mode" = "single" ] || [ "$mode" = "literal_single" ]; then
    echo "[Error] Failed to parse ${context}: Unterminated single quote" >&2
    return 1
  fi

  if [ "$mode" = "double" ] || [ "$mode" = "literal_double" ]; then
    echo "[Error] Failed to parse ${context}: Unterminated double quote" >&2
    return 1
  fi

  if [ "$escape_next" -eq 1 ]; then
    echo "[Error] Failed to parse ${context}: Unterminated escape sequence" >&2
    return 1
  fi

  if [ "$token_started" -eq 1 ]; then
    tokens+=("$token")
  fi

  if [ "${#tokens[@]}" -eq 0 ]; then
    return 0
  fi

  local token_value
  for token_value in "${tokens[@]}"; do
    if [[ "$token_value" =~ [[:cntrl:]] ]]; then
      echo "[Error] Failed to parse ${context}: control characters are not allowed in docker options" >&2
      return 1
    fi
    printf '%s\n' "$token_value"
  done
}

# Preserve every record terminator, including an empty final argument. Read the
# result through printf, not a here-string, which would add another empty row.
function _parse_docker_opts_capture_lines() {
  local _docl_destination="${1:-}" _docl_captured=""
  [[ "$_docl_destination" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
  _docl_captured="$(_parse_docker_opts_to_lines "${2:-}" "${3:-docker options}" && printf '.')" || return 1
  printf -v "$_docl_destination" '%s' "${_docl_captured%.}"
}
