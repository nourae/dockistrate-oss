# shellcheck shell=bash

function interactive_picker_run_command_prompt() {
  local CMD="$1"
  local skip_availability=false
  local skip_runtime_prep=false

  if declare -F dockistrate_command_skips_runtime_prep >/dev/null 2>&1 &&
    dockistrate_command_skips_runtime_prep "$CMD"; then
    skip_runtime_prep=true
  fi

  if [ "$skip_runtime_prep" != true ] &&
    declare -F dockistrate_prepare_runtime >/dev/null 2>&1; then
    if ! dockistrate_prepare_runtime; then
      echo "[Error] Unable to prepare runtime environment." >&2
      read -rp "Press Enter to continue..." _
      return 1
    fi
  fi

  while true; do
    if [ "${INTERACTIVE:-}" = true ] &&
      [ "$skip_availability" != true ] &&
      declare -F interactive_command_availability >/dev/null 2>&1 &&
      declare -F interactive_no_state_guidance >/dev/null 2>&1; then
      if ! interactive_command_availability "$CMD"; then
        local guidance_status=0 guidance_action=""
        interactive_no_state_guidance "$CMD"
        guidance_status=$?
        case "$guidance_status" in
        0)
          guidance_action="${INTERACTIVE_NO_STATE_ACTION:-}"
          if [ -n "$guidance_action" ]; then
            CMD="$guidance_action"
            continue
          fi
          ;;
        2)
          SELECTED_CMD=""
          SELECTED_ARGS=()
          return 2
          ;;
        3)
          skip_availability=true
          continue
          ;;
        esac

        SELECTED_CMD=""
        SELECTED_ARGS=()
        return 1
      fi
    fi

    skip_availability=false
    prompt_args_for_command "$CMD"
    local prompt_status=$?
    if [ "$prompt_status" -eq 0 ]; then
      return 0
    fi
    if [ "$prompt_status" -eq 2 ]; then
      continue
    fi

    SELECTED_CMD=""
    SELECTED_ARGS=()
    return 1
  done
}

function interactive_picker_choose_command_list() {
  local prompt="$1"
  shift
  local commands=("$@")
  # shellcheck disable=SC2034
  local filter=""

  while true; do
    local CMD=""
    if ! choose_command_with_filter CMD filter "$prompt" "${commands[@]}"; then
      return 1
    fi
    interactive_picker_run_command_prompt "$CMD"
    local run_status=$?
    if [ "$run_status" -eq 0 ]; then
      return 0
    fi
    if [ "$run_status" -eq 2 ]; then
      return 2
    fi
  done
}

function interactive_picker_search_all_commands() {
  # shellcheck disable=SC2034
  local global_filter=""

  while true; do
    local CMD=""
    if ! choose_global_command_with_filter CMD global_filter "Search all commands:"; then
      return 1
    fi
    interactive_picker_run_command_prompt "$CMD"
    local run_status=$?
    if [ "$run_status" -eq 0 ]; then
      return 0
    fi
    if [ "$run_status" -eq 2 ]; then
      return 2
    fi
  done
}

function interactive_command_browser() {
  local caller_mode="${1:-direct}"
  local categories=("Search all commands" "${INTERACTIVE_PICKER_CATEGORIES[@]}")
  # shellcheck disable=SC2034
  local global_filter=""

  while true; do
    local cat_idx choose_status=0
    if [ "$caller_mode" = "home" ]; then
      choose_option_with_context_status choose_status cat_idx "command-browser-category" "=== Dockistrate Command Browser ===\nSelect a category:" "${categories[@]}" "Back to home" "Quit"
    else
      choose_option_with_context_status choose_status cat_idx "command-browser-category" "=== Dockistrate Command Browser ===\nSelect a category:" "${categories[@]}" "Quit"
    fi
    if [ "$choose_status" -ne 0 ]; then
      return 1
    fi
    if [ "$caller_mode" = "home" ] && ((cat_idx == ${#categories[@]})); then
      return 1
    fi
    if [ "$caller_mode" = "home" ] && ((cat_idx == ${#categories[@]} + 1)); then
      return 2
    fi
    if ((cat_idx == ${#categories[@]})); then
      return 1
    fi

    local category="${categories[$cat_idx]}"
    if [ "$category" = "Search all commands" ]; then
      # Keep this browser-local loop so returning to categories preserves the
      # command-browser search filter for the current browser session.
      while true; do
        local CMD=""
        if ! choose_global_command_with_filter CMD global_filter "Search all commands:"; then
          break
        fi
        interactive_picker_run_command_prompt "$CMD"
        local run_status=$?
        if [ "$run_status" -eq 0 ]; then
          return 0
        fi
        if [ "$run_status" -eq 2 ]; then
          [ "$caller_mode" = "home" ] && return 2
          return 1
        fi
      done
      continue
    fi

    if ! interactive_picker_commands_for_category "$category"; then
      echo "[Error] Unknown interactive category: ${category}" >&2
      read -rp "Press Enter to continue..." _
      continue
    fi

    interactive_picker_choose_command_list "Choose a command from $category:" "${INTERACTIVE_PICKER_CATEGORY_COMMANDS[@]}"
    local list_status=$?
    if [ "$list_status" -eq 0 ]; then
      return 0
    fi
    if [ "$list_status" -eq 2 ]; then
      [ "$caller_mode" = "home" ] && return 2
      return 1
    fi
  done
}

function interactive_picker_run_home_action() {
  local action="$1"

  case "$action" in
  "$INTERACTIVE_PICKER_HOME_ADD_BACKEND_LABEL")
    interactive_picker_run_command_prompt "add-backend"
    ;;
  "$INTERACTIVE_PICKER_HOME_RECENTS_LABEL")
    interactive_picker_recent_commands
    ;;
  "$INTERACTIVE_PICKER_HOME_FAVORITES_LABEL")
    interactive_picker_favorite_commands
    ;;
  "$INTERACTIVE_PICKER_HOME_PORTS_LABEL")
    interactive_picker_choose_command_list "${INTERACTIVE_PICKER_HOME_PORTS_LABEL}:" \
      "${INTERACTIVE_PICKER_HOME_COMMANDS_PORTS[@]}"
    ;;
  "$INTERACTIVE_PICKER_HOME_SERVICES_LABEL")
    interactive_picker_choose_command_list "${INTERACTIVE_PICKER_HOME_SERVICES_LABEL}:" \
      "${INTERACTIVE_PICKER_HOME_COMMANDS_SERVICES[@]}"
    ;;
  "$INTERACTIVE_PICKER_HOME_CERTIFICATES_LABEL")
    interactive_picker_choose_command_list "${INTERACTIVE_PICKER_HOME_CERTIFICATES_LABEL}:" "${INTERACTIVE_PICKER_COMMANDS_CERTIFICATES[@]}"
    ;;
  "$INTERACTIVE_PICKER_HOME_SECURITY_LABEL")
    interactive_picker_choose_command_list "${INTERACTIVE_PICKER_HOME_SECURITY_LABEL}:" "${INTERACTIVE_PICKER_COMMANDS_ACL_RULES[@]}"
    ;;
  "$INTERACTIVE_PICKER_HOME_UPDATES_LABEL")
    interactive_picker_choose_command_list "${INTERACTIVE_PICKER_HOME_UPDATES_LABEL}:" \
      "${INTERACTIVE_PICKER_HOME_COMMANDS_UPDATES[@]}"
    ;;
  "$INTERACTIVE_PICKER_HOME_DIAGNOSTICS_LABEL")
    interactive_picker_choose_command_list "${INTERACTIVE_PICKER_HOME_DIAGNOSTICS_LABEL}:" \
      "${INTERACTIVE_PICKER_HOME_COMMANDS_DIAGNOSTICS[@]}"
    ;;
  "$INTERACTIVE_PICKER_HOME_SEARCH_LABEL")
    interactive_picker_search_all_commands
    ;;
  "$INTERACTIVE_PICKER_HOME_ADVANCED_LABEL")
    interactive_command_browser home
    ;;
  *)
    echo "[Error] Unknown interactive home action: ${action}" >&2
    read -rp "Press Enter to continue..." _
    return 1
    ;;
  esac
}

function interactive_picker() {
  SELECTED_CMD=""
  SELECTED_ARGS=()

  while true; do
    local home_idx home_prompt="=== Dockistrate ===" dashboard_summary="" choose_status=0
    if declare -F interactive_dashboard_summary >/dev/null 2>&1; then
      dashboard_summary="$(interactive_dashboard_summary 2>/dev/null || true)"
    fi
    if [ -n "$dashboard_summary" ]; then
      home_prompt="${home_prompt}"$'\n'"${dashboard_summary}"
    fi
    home_prompt="${home_prompt}"$'\n'"What do you want to do?"

    choose_option_with_context_status choose_status home_idx "home" "$home_prompt" "${INTERACTIVE_PICKER_HOME_OPTIONS[@]}" "Quit"
    if [ "$choose_status" -ne 0 ]; then
      return 1
    fi
    if ((home_idx == ${#INTERACTIVE_PICKER_HOME_OPTIONS[@]})); then
      return 1
    fi

    local action="${INTERACTIVE_PICKER_HOME_OPTIONS[$home_idx]}"
    interactive_picker_run_home_action "$action"
    local action_status=$?
    if [ "$action_status" -eq 0 ]; then
      return 0
    fi
    if [ "$action_status" -eq 2 ]; then
      return 1
    fi
    # dockistrate.sh reads these globals after interactive_picker returns.
    # shellcheck disable=SC2034
    SELECTED_CMD=""
    # shellcheck disable=SC2034
    SELECTED_ARGS=()
  done
}
