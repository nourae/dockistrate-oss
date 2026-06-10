# shellcheck shell=bash

CLI_CLEAR_SCREEN_AVAILABLE="${CLI_CLEAR_SCREEN_AVAILABLE:-}"

function cli_clear_screen() {
  if [ "${DOCKISTRATE_NO_CLEAR:-false}" = "true" ]; then
    return 0
  fi

  if [ -z "${CLI_CLEAR_SCREEN_AVAILABLE:-}" ]; then
    if command -v clear >/dev/null 2>&1; then
      CLI_CLEAR_SCREEN_AVAILABLE=true
    else
      CLI_CLEAR_SCREEN_AVAILABLE=false
    fi
  fi

  if [ "$CLI_CLEAR_SCREEN_AVAILABLE" = "true" ]; then
    clear
  fi
}

function cli_read_escape_sequence() {
  local __resultvar="${1:-}" __sequence="" __saved_stty="" __stty_changed=false
  require_valid_var_name "$__resultvar" || return 1

  if [ -t 0 ] && command -v stty >/dev/null 2>&1; then
    __saved_stty="$(stty -g 2>/dev/null || true)"
    if [ -n "$__saved_stty" ] && stty -icanon min 0 time 1 2>/dev/null; then
      __stty_changed=true
      IFS= read -rsn2 __sequence || true
    else
      IFS= read -rsn2 -t 1 __sequence || true
    fi
    if $__stty_changed; then
      stty "$__saved_stty" 2>/dev/null || true
    fi
  else
    IFS= read -rsn2 -t 1 __sequence || true
  fi

  printf -v "$__resultvar" '%s' "$__sequence"
  [ -n "$__sequence" ]
}

function cli_render_header() {
  local title="${1:-}"
  [ -n "$title" ] || return 0
  cli_print_prompt "$title"
  cli_render_breadcrumb "${CLI_INTERACTIVE_BREADCRUMB:-}"
}

function cli_render_breadcrumb() {
  local breadcrumb="${1:-}"
  [ -n "$breadcrumb" ] || return 0
  cli_print_prompt "$breadcrumb"
}

function cli_render_help_line() {
  local help_text="${1:-}"
  [ -n "$help_text" ] || return 0
  printf '%s\n' "$help_text"
}

function cli_render_footer() {
  local footer_text="${1:-}"
  [ -n "$footer_text" ] || return 0
  printf '\n%s\n' "$footer_text"
}

function cli_interactive_help_for_context() {
  local context="${1:-generic-choice}"

  case "$context" in
  home)
    printf '%s\n' \
      "Home shows the operator dashboard and top-level tasks." \
      "Use Up/Down or number keys to choose an action." \
      "Enter opens the selected action. Esc or Q exits interactive mode."
    ;;
  command-browser-category)
    printf '%s\n' \
      "The command browser groups every interactive command by category." \
      "Use Up/Down or number keys to choose a category." \
      "Enter opens the selected category. Esc or Q returns/back."
    ;;
  command-list)
    printf '%s\n' \
      "This screen lists commands in the current category." \
      "Use Up/Down or number keys to choose a command." \
      "Search commands with / or S, type to filter, and use C to clear the filter." \
      "Enter selects the highlighted command. Esc or Q returns/back."
    ;;
  global-search)
    printf '%s\n' \
      "Global search lists commands from every interactive category." \
      "Search matches command names, aliases, descriptions, and category names." \
      "Use / or S to search, C to clear, Enter to select, and Esc or Q to return."
    ;;
  no-state-guidance)
    printf '%s\n' \
      "This command needs setup that is not present yet." \
      "Choose the suggested setup action to create the missing state." \
      "Choose Return, Esc, or Q to go back without running a command."
    ;;
  review-before-run)
    printf '%s\n' \
      "Review shows the command, arguments, and CLI equivalent before running." \
      "Choose Run to continue, Edit previous answers to go back, or Cancel to stop." \
      "Destructive commands may also require typing YES after this screen."
    ;;
  saved-command-list)
    printf '%s\n' \
      "Recent commands and favorites let you rerun saved interactive selections." \
      "Choose a saved command to review, run, favorite, or unfavorite it." \
      "Esc or Q returns/back without running a saved command."
    ;;
  *)
    printf '%s\n' \
      "Use Up/Down or number keys to choose an item." \
      "Enter selects the highlighted item." \
      "Esc or Q returns/back."
    ;;
  esac
}

function cli_show_interactive_help() {
  local context="${1:-generic-choice}" title="${2:-Interactive help}" key="" help_text=""
  help_text="$(cli_interactive_help_for_context "$context")"

  cli_clear_screen
  cli_render_header "Help: ${title}"
  printf '%s\n' "$help_text"
  cli_render_footer "Enter return  Esc return  Q return"
  while true; do
    cli_read_keypress key || return 0
    case "$key" in
    "" | [Qq])
      return 0
      ;;
    $'\e')
      if cli_read_escape_sequence key; then
        continue
      fi
      return 0
      ;;
    esac
  done
}
