# shellcheck shell=bash

COMMAND_NAME_LOWER_PREFIX="CMD_NAME_LOWER__"
COMMAND_ALIAS_LOWER_PREFIX="CMD_ALIAS_LOWER__"
COMMAND_DESC_LOWER_PREFIX="CMD_DESC_LOWER__"
COMMAND_DISPLAY_TEXT_PREFIX="CMD_DISPLAY_TEXT__"

function _command_cache_var_name() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __prefix="$2"
  local __command_name="$3"
  local __cache_name="${__prefix}${__command_name//[^A-Za-z0-9_]/_}"
  require_valid_var_name "$__cache_name" || return 1
  printf -v "$__out_var" '%s' "$__cache_name"
}

function _command_cache_get_or_set() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __prefix="$2"
  local __command_name="$3"
  local __command="${4:-}"
  local __cache_var=""
  _command_cache_var_name __cache_var "$__prefix" "$__command_name" || return 1
  local __cached="${!__cache_var-}"
  if [ -n "$__cached" ]; then
    printf -v "$__out_var" '%s' "$__cached"
    return 0
  fi
  printf -v "$__cache_var" '%s' "$__command"
  printf -v "$__out_var" '%s' "$__command"
}

function _command_lower_name() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __command_name="$2"
  local __lowered=""
  _command_cache_get_or_set __lowered "$COMMAND_NAME_LOWER_PREFIX" "$__command_name" "$(printf '%s' "$__command_name" | tr '[:upper:]' '[:lower:]')" || return 1
  printf -v "$__out_var" '%s' "$__lowered"
}

function _command_lower_alias() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __command_name="$2"
  local __alias_text="$3"
  local __lowered=""
  _command_cache_get_or_set __lowered "$COMMAND_ALIAS_LOWER_PREFIX" "$__command_name" "$(printf '%s' "$__alias_text" | tr '[:upper:]' '[:lower:]')" || return 1
  printf -v "$__out_var" '%s' "$__lowered"
}

function _command_lower_desc() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __command_name="$2"
  local __desc_text="$3"
  local __lowered=""
  _command_cache_get_or_set __lowered "$COMMAND_DESC_LOWER_PREFIX" "$__command_name" "$(printf '%s' "$__desc_text" | tr '[:upper:]' '[:lower:]')" || return 1
  printf -v "$__out_var" '%s' "$__lowered"
}

function _command_display_text() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __command_name="$2"
  local __alias_text="$3"
  local __desc_text="$4"
  local __display_text=""
  _command_cache_get_or_set __display_text "$COMMAND_DISPLAY_TEXT_PREFIX" "$__command_name" "$(format_command_display "$__alias_text" "$__desc_text")" || return 1
  printf -v "$__out_var" '%s' "$__display_text"
}

function _command_display_text_for_state() {
  local __out_var="$1"
  require_valid_var_name "$__out_var" || return 1
  local __alias_text="$2"
  local __desc_text="$3"
  local __suffix_text="${4:-}"
  local __display_desc="$__desc_text" __display_text=""

  if [ -n "$__suffix_text" ]; then
    if [ -n "$__display_desc" ]; then
      __display_desc="${__display_desc} — ${__suffix_text}"
    else
      __display_desc="$__suffix_text"
    fi
  fi

  __display_text="$(format_command_display "$__alias_text" "$__display_desc")" || return 1
  printf -v "$__out_var" '%s' "$__display_text"
}

CHOOSE_COMMAND_ENTRY_COMMANDS=()
CHOOSE_COMMAND_ENTRY_DISPLAY_TEXTS=()
CHOOSE_COMMAND_ENTRY_NAMES_LOWER=()
CHOOSE_COMMAND_ENTRY_ALIASES_LOWER=()
CHOOSE_COMMAND_ENTRY_DESCS_LOWER=()
CHOOSE_COMMAND_ENTRY_EXTRA_LOWER=()

function _choose_command_reset_entries() {
  CHOOSE_COMMAND_ENTRY_COMMANDS=()
  CHOOSE_COMMAND_ENTRY_DISPLAY_TEXTS=()
  CHOOSE_COMMAND_ENTRY_NAMES_LOWER=()
  CHOOSE_COMMAND_ENTRY_ALIASES_LOWER=()
  CHOOSE_COMMAND_ENTRY_DESCS_LOWER=()
  CHOOSE_COMMAND_ENTRY_EXTRA_LOWER=()
}

function _choose_command_add_entry() {
  local command="$1"
  local display_text="$2"
  local alias_text="$3"
  local desc_text="$4"
  local extra_lower="${5:-}"
  local lowered_name lowered_alias lowered_desc

  _command_lower_name lowered_name "$command"
  _command_lower_alias lowered_alias "$command" "$alias_text"
  _command_lower_desc lowered_desc "$command" "$desc_text"

  CHOOSE_COMMAND_ENTRY_COMMANDS+=("$command")
  CHOOSE_COMMAND_ENTRY_DISPLAY_TEXTS+=("$display_text")
  CHOOSE_COMMAND_ENTRY_NAMES_LOWER+=("$lowered_name")
  CHOOSE_COMMAND_ENTRY_ALIASES_LOWER+=("$lowered_alias")
  CHOOSE_COMMAND_ENTRY_DESCS_LOWER+=("$lowered_desc")
  CHOOSE_COMMAND_ENTRY_EXTRA_LOWER+=("$extra_lower")
}

function _choose_command_from_prepared_entries() {
  local __resultvar=$1
  local __filtervar=$2
  local prompt="$3"
  local verbose_context="$4"
  local help_context="${5:-command-list}"
  local filter="${!__filtervar:-}"
  local selected=0
  local in_search=false

  while true; do
    local filtered_commands=()
    local display_cmds=()
    local filter_lower
    filter_lower="$(printf '%s' "$filter" | tr '[:upper:]' '[:lower:]')"
    local idx
    for idx in "${!CHOOSE_COMMAND_ENTRY_COMMANDS[@]}"; do
      local matched=false
      if [ -n "$filter_lower" ]; then
        case "${CHOOSE_COMMAND_ENTRY_NAMES_LOWER[$idx]}" in
        *"$filter_lower"*) matched=true ;;
        esac
        case "${CHOOSE_COMMAND_ENTRY_ALIASES_LOWER[$idx]}" in
        *"$filter_lower"*) matched=true ;;
        esac
        case "${CHOOSE_COMMAND_ENTRY_DESCS_LOWER[$idx]}" in
        *"$filter_lower"*) matched=true ;;
        esac
        case "${CHOOSE_COMMAND_ENTRY_EXTRA_LOWER[$idx]:-}" in
        *"$filter_lower"*) matched=true ;;
        esac
        $matched || continue
      fi
      filtered_commands+=("${CHOOSE_COMMAND_ENTRY_COMMANDS[$idx]}")
      display_cmds+=("${CHOOSE_COMMAND_ENTRY_DISPLAY_TEXTS[$idx]}")
    done

    local options=("${display_cmds[@]}" "Back")
    local num_opts=${#options[@]}
    if ((selected >= num_opts)); then
      selected=$((num_opts - 1))
    fi

    cli_clear_screen
    cli_render_header "$prompt"
    if [ -n "$filter" ]; then
      cli_render_help_line "Filter: ${filter}"
    else
      cli_render_help_line "Filter: [none]"
    fi
    if $in_search; then
      cli_render_help_line "Search: type to filter, Enter or Esc to finish searching"
    else
      cli_render_help_line "Press S or / to search, C to clear, Enter to select, ? for help"
    fi
    local i
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        printf '> %d) %s\n' $((i + 1)) "${options[$i]}"
      else
        printf '  %d) %s\n' $((i + 1)) "${options[$i]}"
      fi
    done
    if [ ${#filtered_commands[@]} -eq 0 ]; then
      printf '\nNo commands match the filter.\n'
    fi
    if $in_search; then
      cli_render_footer "Enter finish search  Esc finish search  Backspace delete  ? help"
    else
      cli_render_footer "↑↓ move  Enter select  / search  C clear  Esc back  Q back  ? help"
    fi

    local key next
    if ! cli_read_keypress key; then
      printf -v "$__filtervar" '%s' "$filter"
      printf -v "$__resultvar" '%s' ""
      return 1
    fi
    case "$key" in
    "")
      if $in_search; then
        in_search=false
        continue
      fi
      if ((selected == ${#filtered_commands[@]})); then
        printf -v "$__filtervar" '%s' "$filter"
        printf -v "$__resultvar" '%s' ""
        return 1
      fi
      printf -v "$__filtervar" '%s' "$filter"
      printf -v "$__resultvar" '%s' "${filtered_commands[$selected]}"
      return 0
      ;;
    $'\e')
      if cli_read_escape_sequence next; then
        case "$next" in
        "[A") selected=$(((selected - 1 + num_opts) % num_opts)) ;;
        "[B") selected=$(((selected + 1) % num_opts)) ;;
        esac
      else
        if $in_search; then
          in_search=false
        else
          printf -v "$__filtervar" '%s' "$filter"
          printf -v "$__resultvar" '%s' ""
          return 1
        fi
      fi
      continue
      ;;
    $'\x7f' | $'\b')
      if $in_search; then
        filter="${filter%?}"
        selected=0
      fi
      continue
      ;;
    esac

    if [ "$key" = "?" ]; then
      if declare -F cli_show_interactive_help >/dev/null 2>&1; then
        cli_show_interactive_help "$help_context" "$prompt"
      fi
      continue
    fi

    if ! $in_search; then
      case "$key" in
      [Ss] | "/")
        in_search=true
        continue
        ;;
      [Cc])
        filter=""
        selected=0
        continue
        ;;
      [Qq])
        printf -v "$__filtervar" '%s' "$filter"
        printf -v "$__resultvar" '%s' ""
        return 1
        ;;
      [1-9])
        local number="$key"
        while true; do
          if IFS= read -rsn1 -t 1 next; then
            if [[ "$next" =~ [0-9] ]]; then
              number+="$next"
              continue
            fi
            if [ -z "$next" ] || [ "$next" = $'\n' ]; then
              break
            fi
            break
          else
            break
          fi
        done
        if [[ "$number" =~ ^[0-9]+$ ]]; then
          local chosen=$((10#$number))
          if ((chosen >= 1 && chosen <= num_opts)); then
            if ((chosen - 1 == ${#filtered_commands[@]})); then
              printf -v "$__filtervar" '%s' "$filter"
              printf -v "$__resultvar" '%s' ""
              return 1
            fi
            printf -v "$__filtervar" '%s' "$filter"
            printf -v "$__resultvar" '%s' "${filtered_commands[$((chosen - 1))]}"
            if [ "${VERBOSE:-false}" = true ]; then
              printf '[Verbose] %s numeric input %s -> %s\n' "$verbose_context" "$number" "${filtered_commands[$((chosen - 1))]}" >&2
            fi
            return 0
          fi
        fi
        ;;
      esac
    fi

    if $in_search; then
      if [[ "$key" =~ [[:print:]] ]]; then
        filter+="$key"
        selected=0
      fi
    fi
  done
}

function choose_command_with_filter() {
  local __resultvar=$1
  local __filtervar=$2
  local prompt="$3"
  shift 3
  local commands=("$@")
  local command display desc display_text suffix suffix_lower
  local suffix_cache_started=false
  local suffix_helper_available=false

  _choose_command_reset_entries
  if declare -F interactive_command_display_suffix >/dev/null 2>&1; then
    suffix_helper_available=true
  fi
  if declare -F interactive_command_display_suffix_cache_begin >/dev/null 2>&1 &&
    declare -F interactive_command_display_suffix_cache_end >/dev/null 2>&1; then
    interactive_command_display_suffix_cache_begin
    suffix_cache_started=true
  fi
  for command in "${commands[@]}"; do
    display="$(command_alias "$command")"
    desc="$(command_description "$command")"
    suffix=""
    suffix_lower=""
    if [ "$suffix_helper_available" = true ]; then
      interactive_command_display_suffix "$command" suffix
      if [ -n "$suffix" ]; then
        suffix_lower="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
      fi
    fi
    _command_display_text_for_state display_text "$display" "$desc" "$suffix"
    _choose_command_add_entry "$command" "$display_text" "$display" "$desc" "$suffix_lower"
  done
  if [ "$suffix_cache_started" = true ]; then
    interactive_command_display_suffix_cache_end
  fi

  _choose_command_from_prepared_entries "$__resultvar" "$__filtervar" "$prompt" "interactive_picker" "command-list"
}

function choose_global_command_with_filter() {
  local __resultvar=$1
  local __filtervar=$2
  local prompt="$3"
  local commands=()
  local command_categories=()
  local idx command category display desc display_text category_lower suffix suffix_lower extra_lower
  local suffix_cache_started=false
  local suffix_helper_available=false

  interactive_flatten_picker_commands || return 1
  commands=("${INTERACTIVE_PICKER_FLATTENED_COMMANDS[@]}")
  command_categories=("${INTERACTIVE_PICKER_FLATTENED_CATEGORIES[@]}")

  _choose_command_reset_entries
  if declare -F interactive_command_display_suffix >/dev/null 2>&1; then
    suffix_helper_available=true
  fi
  if declare -F interactive_command_display_suffix_cache_begin >/dev/null 2>&1 &&
    declare -F interactive_command_display_suffix_cache_end >/dev/null 2>&1; then
    interactive_command_display_suffix_cache_begin
    suffix_cache_started=true
  fi
  for idx in "${!commands[@]}"; do
    command="${commands[$idx]}"
    category="${command_categories[$idx]}"
    display="$(command_alias "$command")"
    desc="$(command_description "$command")"
    suffix=""
    suffix_lower=""
    if [ "$suffix_helper_available" = true ]; then
      interactive_command_display_suffix "$command" suffix
      if [ -n "$suffix" ]; then
        suffix_lower="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
      fi
    fi
    _command_display_text_for_state display_text "${category} :: ${display}" "$desc" "$suffix"
    category_lower="$(printf '%s' "$category" | tr '[:upper:]' '[:lower:]')"
    extra_lower="$category_lower"
    if [ -n "$suffix_lower" ]; then
      extra_lower="${extra_lower}"$'\n'"${suffix_lower}"
    fi
    _choose_command_add_entry "$command" "$display_text" "$display" "$desc" "$extra_lower"
  done
  if [ "$suffix_cache_started" = true ]; then
    interactive_command_display_suffix_cache_end
  fi

  _choose_command_from_prepared_entries "$__resultvar" "$__filtervar" "$prompt" "interactive_global_search" "global-search"
}
