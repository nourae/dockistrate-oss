# shellcheck shell=bash

# Present a numbered menu allowing navigation with arrow keys
# Arguments:
#   $1 - variable name to store the selected index (0-based)
#   $2 - prompt to display above the options
#   Remaining arguments - menu options
function choose_option() {
  local __resultvar=$1
  require_valid_var_name "$__resultvar" || return 1
  local prompt="$2"
  shift 2
  local options=("$@")
  local selected=0 key num_opts=${#options[@]} i

  while true; do
    cli_clear_screen
    cli_render_header "$prompt"
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf '> %d) %s\n' $((i + 1)) "${options[$i]}"
      else
        printf '  %d) %s\n' $((i + 1)) "${options[$i]}"
      fi
    done
    cli_render_footer "↑↓ move  Enter select  Esc back  Q back  ? help"
    if ! cli_read_keypress key; then
      printf -v "$__resultvar" '%s' ""
      return 1
    fi
    case "$key" in
    "")
      printf -v "$__resultvar" '%d' "$selected"
      return
      ;;
    [Qq])
      printf -v "$__resultvar" '%s' ""
      return 1
      ;;
    "?")
      if declare -F cli_show_interactive_help >/dev/null 2>&1; then
        cli_show_interactive_help "${CLI_INTERACTIVE_CONTEXT:-generic-choice}" "$prompt"
      fi
      ;;
    [1-9])
      local number="$key" next
      while true; do
        if IFS= read -rsn1 -t 1 next; then
          if [[ "$next" =~ [0-9] ]]; then
            number+="$next"
            continue
          fi
          if [ -z "$next" ] || [ "$next" = $'\n' ]; then
            break
          fi
          # Non numeric input terminates multi-digit capture
          break
        else
          break
        fi
      done
      if [[ "$number" =~ ^[0-9]+$ ]]; then
        local chosen=$((10#$number))
        if ((chosen >= 1 && chosen <= num_opts)); then
          if [ "${VERBOSE:-false}" = true ]; then
            printf '[Verbose] choose_option numeric input %s -> %s\n' "$number" "${options[$((chosen - 1))]}" >&2
          fi
          printf -v "$__resultvar" '%d' "$((chosen - 1))"
          return
        fi
      fi
      ;;
    $'\e')
      if cli_read_escape_sequence key; then
        case "$key" in
        "[A") selected=$(((selected - 1 + num_opts) % num_opts)) ;;
        "[B") selected=$(((selected + 1) % num_opts)) ;;
        esac
      else
        printf -v "$__resultvar" '%s' ""
        return 1
      fi
      ;;
    esac
  done
}

function _choose_option_require_valid_var_name() {
  if declare -F require_valid_var_name >/dev/null 2>&1; then
    require_valid_var_name "${1:-}"
    return $?
  fi

  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

function choose_option_with_context_status() {
  [ "$#" -ge 4 ] || return 1

  local __statusvar="$1"
  local __resultvar="$2"
  local context="$3"
  local prompt="$4"
  shift 4

  _choose_option_require_valid_var_name "$__statusvar" || return 1
  _choose_option_require_valid_var_name "$__resultvar" || return 1

  local old_context="" old_context_was_set=false __choose_option_status=0
  if [ "${CLI_INTERACTIVE_CONTEXT+x}" = "x" ]; then
    old_context="$CLI_INTERACTIVE_CONTEXT"
    old_context_was_set=true
  fi

  CLI_INTERACTIVE_CONTEXT="$context"
  if choose_option "$__resultvar" "$prompt" "$@"; then
    __choose_option_status=0
  else
    __choose_option_status=$?
  fi

  if [ "$old_context_was_set" = true ]; then
    CLI_INTERACTIVE_CONTEXT="$old_context"
  else
    unset CLI_INTERACTIVE_CONTEXT
  fi

  printf -v "$__statusvar" '%d' "$__choose_option_status"
  return 0
}
