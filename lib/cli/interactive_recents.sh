# shellcheck shell=bash

STATE_INTERACTIVE_RECENTS_HEADER="timestamp,command,arg_count,args_csv"
STATE_INTERACTIVE_RECENTS_COLS=4
STATE_INTERACTIVE_FAVORITES_HEADER="command,arg_count,args_csv"
STATE_INTERACTIVE_FAVORITES_COLS=3
INTERACTIVE_RECENTS_LIMIT="${INTERACTIVE_RECENTS_LIMIT:-10}"

INTERACTIVE_SAVED_TIMESTAMPS=()
INTERACTIVE_SAVED_COMMANDS=()
INTERACTIVE_SAVED_ARG_COUNTS=()
INTERACTIVE_SAVED_ARGS_CSV=()
INTERACTIVE_SAVED_ARGS=()
INTERACTIVE_SAVED_DISPLAYS=()

function interactive_recents_limit() {
  local limit="${INTERACTIVE_RECENTS_LIMIT:-10}"

  case "$limit" in
  '' | *[!0-9]*)
    limit=10
    ;;
  esac
  if [ "$limit" -lt 1 ] 2>/dev/null; then
    limit=1
  fi

  printf '%s\n' "$limit"
}

function interactive_recent_file() {
  printf '%s\n' "${INTERACTIVE_RECENT_FILE:-${CONFIG_DIR}/interactive_recent.csv}"
}

function interactive_favorites_file() {
  printf '%s\n' "${INTERACTIVE_FAVORITES_FILE:-${CONFIG_DIR}/interactive_favorites.csv}"
}

function interactive_recents_now() {
  if [ -n "${INTERACTIVE_RECENTS_NOW:-}" ]; then
    printf '%s\n' "$INTERACTIVE_RECENTS_NOW"
  else
    date '+%Y-%m-%dT%H:%M:%S%z'
  fi
}

function _interactive_command_args_csv() {
  local args_csv
  args_csv="$(csv_join_row "$@")"
  args_csv="${args_csv%$'\n'}"
  printf '%s' "$args_csv"
}

function _interactive_saved_parse_args() {
  local arg_count="${1:-0}" args_csv="${2:-}"
  INTERACTIVE_SAVED_ARGS=()

  if [ "$arg_count" -eq 0 ] 2>/dev/null; then
    return 0
  fi
  if ! csv_parse_line "$args_csv"; then
    echo "[Error] Invalid saved interactive args CSV: ${CSV_PARSE_ERROR}" >&2
    return 1
  fi
  if [ "$CSV_FIELD_COUNT" -ne "$arg_count" ]; then
    echo "[Error] Invalid saved interactive arg count: expected ${arg_count}, got ${CSV_FIELD_COUNT}" >&2
    return 1
  fi
  INTERACTIVE_SAVED_ARGS=("${CSV_FIELDS[@]}")
}

function _interactive_saved_args_have_sensitive_values() {
  local cmd="${1:-}"
  if [ "${#INTERACTIVE_SAVED_ARGS[@]}" -gt 0 ] 2>/dev/null; then
    interactive_command_has_sensitive_args "$cmd" "${INTERACTIVE_SAVED_ARGS[@]}"
  else
    interactive_command_has_sensitive_args "$cmd"
  fi
}

function _interactive_arg_name_for_option() {
  local __arg_name_var="${1:-}" option="${2:-}"
  local normalized spec_arg_name

  require_valid_var_name "$__arg_name_var" || return 1
  case "$option" in
  --*) normalized="${option#--}" ;;
  *) return 1 ;;
  esac
  normalized="${normalized//-/_}"
  [ "${#CLI_SPEC_NAMES[@]}" -gt 0 ] 2>/dev/null || return 1

  for spec_arg_name in "${CLI_SPEC_NAMES[@]}"; do
    if [ "$spec_arg_name" = "$normalized" ]; then
      printf -v "$__arg_name_var" '%s' "$spec_arg_name"
      return 0
    fi
  done

  return 1
}

function _interactive_sensitive_arg_consumes_remainder() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  set-nginx-docker-opts:docker_opts)
    return 0
    ;;
  esac
  return 1
}

function _interactive_sensitive_arg_redacts_trailing_words() {
  local cmd="${1:-}" arg_name="${2:-}"
  case "${cmd}:${arg_name}" in
  add-header:value | update-header:value \
  | add-backend-header:value | update-backend-header:value \
  | set-hsts:hsts_value | set-backend-hsts:backend_hsts_value \
  | set-csp:csp_value | set-backend-csp:backend_csp_value)
    return 0
    ;;
  esac
  return 1
}

function _interactive_next_arg_is_cli_option() {
  local next_arg="${1:-}" option="" arg_name=""
  [ -n "$next_arg" ] || return 1
  option="$next_arg"
  if [[ "$next_arg" == --*=* ]]; then
    option="${next_arg%%=*}"
  fi
  _interactive_arg_name_for_option arg_name "$option"
}

function _interactive_should_redact_sensitive_trailing_words() {
  local cmd="${1:-}" arg_name="${2:-}" next_arg="${3:-}"
  [ -n "$arg_name" ] || return 1
  [ -n "$next_arg" ] || return 1
  arg_is_sensitive "$cmd" "$arg_name" || return 1
  if _interactive_sensitive_arg_redacts_trailing_words "$cmd" "$arg_name" ||
    [ "$arg_name" = "docker_opts" ]; then
    ! _interactive_next_arg_is_cli_option "$next_arg"
    return
  fi
  return 1
}

function _interactive_should_redact_sensitive_remainder() {
  local cmd="${1:-}" arg_name="${2:-}" idx="${3:-0}" arg_count="${4:-0}"
  [ -n "$arg_name" ] || return 1
  arg_is_sensitive "$cmd" "$arg_name" || return 1
  _interactive_sensitive_arg_consumes_remainder "$cmd" "$arg_name" || return 1
  [ "$idx" -lt "$((arg_count - 1))" ] 2>/dev/null
}

function interactive_command_has_sensitive_args() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  local spec="" idx=0 arg="" option="" option_value="" arg_name="" saw_known_option=false next_arg="" trailing_arg="" has_inline_option_value=false

  declare -F arg_is_sensitive >/dev/null 2>&1 || return 1
  declare -F get_arg_spec >/dev/null 2>&1 || return 1

  spec="$(get_arg_spec "$cmd" 2>/dev/null || true)"
  [ -n "$spec" ] || return 1
  cli_parse_arg_spec "$spec"
  [ "${#args[@]}" -gt 0 ] || return 1

  for idx in "${!args[@]}"; do
    arg="${args[$idx]}"
    option="$arg"
    option_value=""
    has_inline_option_value=false
    if [[ "$arg" == --*=* ]]; then
      option="${arg%%=*}"
      option_value="${arg#*=}"
      has_inline_option_value=true
    fi

    if _interactive_arg_name_for_option arg_name "$option"; then
      saw_known_option=true
      next_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 1))" ]; then
        next_arg="${args[$((idx + 1))]}"
      fi
      trailing_arg=""
      if [ "$idx" -lt "$((${#args[@]} - 2))" ]; then
        trailing_arg="${args[$((idx + 2))]}"
      fi
      if [ "$has_inline_option_value" = true ]; then
        arg_is_sensitive "$cmd" "$arg_name" "$option_value" && return 0
        _interactive_should_redact_sensitive_trailing_words "$cmd" "$arg_name" "$next_arg" && return 0
      else
        arg_is_sensitive "$cmd" "$arg_name" "$next_arg" && return 0
        _interactive_should_redact_sensitive_trailing_words "$cmd" "$arg_name" "$trailing_arg" && return 0
      fi
    fi
  done
  [ "$saw_known_option" = true ] && return 1

  for idx in "${!args[@]}"; do
    [ "$idx" -lt "${#CLI_SPEC_NAMES[@]}" ] || break
    arg_name="${CLI_SPEC_NAMES[$idx]}"
    if arg_is_sensitive "$cmd" "$arg_name" "${args[$idx]}"; then
      return 0
    fi
    if _interactive_should_redact_sensitive_remainder "$cmd" "$arg_name" "$idx" "${#args[@]}"; then
      return 0
    fi
  done

  return 1
}

function interactive_record_recent_command() {
  local cmd="${1:-}"
  shift || true
  local file timestamp arg_count args_csv tmp_file line line_no kept recents_limit
  local existing_cmd existing_arg_count existing_args_csv

  [ -n "$cmd" ] || return 0
  if interactive_command_has_sensitive_args "$cmd" "$@"; then
    return 0
  fi

  file="$(interactive_recent_file)"
  mkdir -p "$(dirname "$file")"
  csv_require_header "$file" "$STATE_INTERACTIVE_RECENTS_HEADER" || return 1

  timestamp="$(interactive_recents_now)"
  arg_count="$#"
  args_csv="$(_interactive_command_args_csv "$@")"
  recents_limit="$(interactive_recents_limit)"

  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$STATE_INTERACTIVE_RECENTS_HEADER" >"$tmp_file"
  csv_join_row "$timestamp" "$cmd" "$arg_count" "$args_csv" >>"$tmp_file"

  line_no=0
  kept=1
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_INTERACTIVE_RECENTS_COLS" ]; then
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${STATE_INTERACTIVE_RECENTS_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi

    existing_cmd="${CSV_FIELDS[1]}"
    existing_arg_count="${CSV_FIELDS[2]}"
    existing_args_csv="${CSV_FIELDS[3]}"
    if [ "$existing_cmd" = "$cmd" ] && [ "$existing_arg_count" = "$arg_count" ] && [ "$existing_args_csv" = "$args_csv" ]; then
      continue
    fi
    if [ "$kept" -ge "$recents_limit" ]; then
      continue
    fi
    csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
    kept=$((kept + 1))
  done <"$file"

  finalize_temp_file "$file" "$tmp_file"
}

function interactive_load_recent_commands() {
  local file line line_no saved_timestamp saved_cmd saved_arg_count saved_args_csv
  file="$(interactive_recent_file)"
  INTERACTIVE_SAVED_TIMESTAMPS=()
  INTERACTIVE_SAVED_COMMANDS=()
  INTERACTIVE_SAVED_ARG_COUNTS=()
  INTERACTIVE_SAVED_ARGS_CSV=()

  mkdir -p "$(dirname "$file")"
  csv_require_header "$file" "$STATE_INTERACTIVE_RECENTS_HEADER" || return 1

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_INTERACTIVE_RECENTS_COLS" ]; then
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${STATE_INTERACTIVE_RECENTS_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    saved_timestamp="${CSV_FIELDS[0]}"
    saved_cmd="${CSV_FIELDS[1]}"
    saved_arg_count="${CSV_FIELDS[2]}"
    saved_args_csv="${CSV_FIELDS[3]}"
    if _interactive_saved_parse_args "$saved_arg_count" "$saved_args_csv" &&
      _interactive_saved_args_have_sensitive_values "$saved_cmd"; then
      continue
    fi
    INTERACTIVE_SAVED_TIMESTAMPS+=("$saved_timestamp")
    INTERACTIVE_SAVED_COMMANDS+=("$saved_cmd")
    INTERACTIVE_SAVED_ARG_COUNTS+=("$saved_arg_count")
    INTERACTIVE_SAVED_ARGS_CSV+=("$saved_args_csv")
  done <"$file"
}

function interactive_load_favorite_commands() {
  local file line line_no saved_cmd saved_arg_count saved_args_csv
  file="$(interactive_favorites_file)"
  INTERACTIVE_SAVED_TIMESTAMPS=()
  INTERACTIVE_SAVED_COMMANDS=()
  INTERACTIVE_SAVED_ARG_COUNTS=()
  INTERACTIVE_SAVED_ARGS_CSV=()

  mkdir -p "$(dirname "$file")"
  csv_require_header "$file" "$STATE_INTERACTIVE_FAVORITES_HEADER" || return 1

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_INTERACTIVE_FAVORITES_COLS" ]; then
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${STATE_INTERACTIVE_FAVORITES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    fi
    saved_cmd="${CSV_FIELDS[0]}"
    saved_arg_count="${CSV_FIELDS[1]}"
    saved_args_csv="${CSV_FIELDS[2]}"
    if _interactive_saved_parse_args "$saved_arg_count" "$saved_args_csv" &&
      _interactive_saved_args_have_sensitive_values "$saved_cmd"; then
      continue
    fi
    INTERACTIVE_SAVED_TIMESTAMPS+=("")
    INTERACTIVE_SAVED_COMMANDS+=("$saved_cmd")
    INTERACTIVE_SAVED_ARG_COUNTS+=("$saved_arg_count")
    INTERACTIVE_SAVED_ARGS_CSV+=("$saved_args_csv")
  done <"$file"
}

function interactive_favorite_has_entry() {
  local cmd="${1:-}" arg_count="${2:-0}" args_csv="${3:-}"
  local file line line_no
  file="$(interactive_favorites_file)"
  [ -f "$file" ] || return 1
  csv_require_header "$file" "$STATE_INTERACTIVE_FAVORITES_HEADER" || return 1

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || return 1
    [ "$CSV_FIELD_COUNT" -eq "$STATE_INTERACTIVE_FAVORITES_COLS" ] || return 1
    if [ "${CSV_FIELDS[0]}" = "$cmd" ] && [ "${CSV_FIELDS[1]}" = "$arg_count" ] && [ "${CSV_FIELDS[2]}" = "$args_csv" ]; then
      return 0
    fi
  done <"$file"

  return 1
}

function interactive_favorite_command() {
  local cmd="${1:-}" arg_count="${2:-0}" args_csv="${3:-}" file tmp_file line line_no
  [ -n "$cmd" ] || return 1
  if _interactive_saved_parse_args "$arg_count" "$args_csv" &&
    _interactive_saved_args_have_sensitive_values "$cmd"; then
    return 0
  fi
  file="$(interactive_favorites_file)"
  mkdir -p "$(dirname "$file")"
  csv_require_header "$file" "$STATE_INTERACTIVE_FAVORITES_HEADER" || return 1
  if interactive_favorite_has_entry "$cmd" "$arg_count" "$args_csv"; then
    return 0
  fi

  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$STATE_INTERACTIVE_FAVORITES_HEADER" >"$tmp_file"
  csv_join_row "$cmd" "$arg_count" "$args_csv" >>"$tmp_file"

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    [ "$CSV_FIELD_COUNT" -eq "$STATE_INTERACTIVE_FAVORITES_COLS" ] || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${STATE_INTERACTIVE_FAVORITES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    }
    if [ "${CSV_FIELDS[0]}" = "$cmd" ] && [ "${CSV_FIELDS[1]}" = "$arg_count" ] && [ "${CSV_FIELDS[2]}" = "$args_csv" ]; then
      continue
    fi
    csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
  done <"$file"

  finalize_temp_file "$file" "$tmp_file"
}

function interactive_unfavorite_command() {
  local cmd="${1:-}" arg_count="${2:-0}" args_csv="${3:-}" file tmp_file line line_no
  file="$(interactive_favorites_file)"
  mkdir -p "$(dirname "$file")"
  csv_require_header "$file" "$STATE_INTERACTIVE_FAVORITES_HEADER" || return 1
  make_temp_for_file tmp_file "$file" || return 1
  printf '%s\n' "$STATE_INTERACTIVE_FAVORITES_HEADER" >"$tmp_file"

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV row in ${file} at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    }
    [ "$CSV_FIELD_COUNT" -eq "$STATE_INTERACTIVE_FAVORITES_COLS" ] || {
      rm -f "$tmp_file"
      echo "[Error] Invalid CSV column count in ${file} at line ${line_no}: expected ${STATE_INTERACTIVE_FAVORITES_COLS}, got ${CSV_FIELD_COUNT}" >&2
      return 1
    }
    if [ "${CSV_FIELDS[0]}" = "$cmd" ] && [ "${CSV_FIELDS[1]}" = "$arg_count" ] && [ "${CSV_FIELDS[2]}" = "$args_csv" ]; then
      continue
    fi
    csv_join_row "${CSV_FIELDS[@]}" >>"$tmp_file"
  done <"$file"

  finalize_temp_file "$file" "$tmp_file"
}

function _interactive_saved_command_display() {
  local cmd="${1:-}" arg_count="${2:-0}" args_csv="${3:-}" prefix="${4:-}"
  local -a args=()
  local display alias cli

  if _interactive_saved_parse_args "$arg_count" "$args_csv"; then
    if [ "${#INTERACTIVE_SAVED_ARGS[@]}" -gt 0 ] 2>/dev/null; then
      args=("${INTERACTIVE_SAVED_ARGS[@]}")
    else
      args=()
    fi
  else
    args=()
  fi

  alias="$(command_alias "$cmd")"
  if [ ${#args[@]} -gt 0 ]; then
    cli="$(format_cli_equivalent "$cmd" "${args[@]}")"
  else
    cli="$(format_cli_equivalent "$cmd")"
  fi
  if [ "$alias" = "$cmd" ]; then
    display="$cmd"
  else
    display="$alias ($cmd)"
  fi
  [ -n "$prefix" ] && display="${prefix} :: ${display}"
  printf '%s - %s' "$display" "$cli"
}

function _interactive_saved_fill_displays() {
  local _idx
  INTERACTIVE_SAVED_DISPLAYS=()
  for _idx in "${!INTERACTIVE_SAVED_COMMANDS[@]}"; do
    INTERACTIVE_SAVED_DISPLAYS+=("$(_interactive_saved_command_display \
      "${INTERACTIVE_SAVED_COMMANDS[$_idx]}" \
      "${INTERACTIVE_SAVED_ARG_COUNTS[$_idx]}" \
      "${INTERACTIVE_SAVED_ARGS_CSV[$_idx]}" \
      "${INTERACTIVE_SAVED_TIMESTAMPS[$_idx]}")")
  done
}

function interactive_picker_run_saved_command() {
  local cmd="${1:-}"
  shift || true
  local args=("$@")
  local review_status=0 guidance_status=0 guidance_action="" skip_availability=false

  if [ "${INTERACTIVE:-}" = true ] &&
    declare -F interactive_command_availability >/dev/null 2>&1 &&
    declare -F interactive_no_state_guidance >/dev/null 2>&1; then
    if ! interactive_command_availability "$cmd"; then
      interactive_no_state_guidance "$cmd"
      guidance_status=$?
      case "$guidance_status" in
      0)
        guidance_action="${INTERACTIVE_NO_STATE_ACTION:-}"
        if [ -n "$guidance_action" ]; then
          interactive_picker_run_command_prompt "$guidance_action"
          return $?
        fi
        ;;
      2)
        SELECTED_CMD=""
        SELECTED_ARGS=()
        return 2
        ;;
      3)
        skip_availability=true
        ;;
      esac

      if [ "$skip_availability" != true ]; then
        SELECTED_CMD=""
        SELECTED_ARGS=()
        return 1
      fi
    fi
  fi

  if [ ${#args[@]} -gt 0 ]; then
    review_command_before_run "$cmd" "${args[@]}"
  else
    review_command_before_run "$cmd"
  fi
  review_status=$?
  case "$review_status" in
  0)
    if declare -F dockistrate_prepare_runtime >/dev/null 2>&1; then
      if ! dockistrate_prepare_runtime; then
        echo "[Error] Unable to prepare runtime environment." >&2
        return 1
      fi
    fi
    SELECTED_CMD="$cmd"
    if [ ${#args[@]} -gt 0 ]; then
      SELECTED_ARGS=("${args[@]}")
    else
      SELECTED_ARGS=()
    fi
    return 0
    ;;
  2)
    interactive_picker_run_command_prompt "$cmd"
    return $?
    ;;
  *)
    # dockistrate.sh reads these globals after interactive_picker returns.
    # shellcheck disable=SC2034
    SELECTED_CMD=""
    # shellcheck disable=SC2034
    SELECTED_ARGS=()
    return 1
    ;;
  esac
}

function interactive_picker_choose_saved_entry() {
  local title="${1:-Saved commands}" source_label="${2:-recent}"
  local idx action_idx favorite_label cmd arg_count args_csv display choose_status=0
  local -a displays=() args=()

  if [ "$source_label" = "favorites" ]; then
    interactive_load_favorite_commands || return 1
  else
    interactive_load_recent_commands || return 1
  fi

  if [ "${#INTERACTIVE_SAVED_COMMANDS[@]}" -eq 0 ]; then
    choose_option_with_context_status choose_status idx "saved-command-list" "${title}\nNo saved commands yet." "Return to previous menu" "Quit"
    if [ "$choose_status" -ne 0 ]; then
      return 1
    fi
    [ "$idx" -eq 1 ] 2>/dev/null && return 2
    return 1
  fi

  _interactive_saved_fill_displays
  if [ "${#INTERACTIVE_SAVED_DISPLAYS[@]}" -gt 0 ] 2>/dev/null; then
    displays=("${INTERACTIVE_SAVED_DISPLAYS[@]}")
  else
    displays=()
  fi

  while true; do
    choose_option_with_context_status choose_status idx "saved-command-list" "$title" "${displays[@]}" "Back" "Quit"
    if [ "$choose_status" -ne 0 ]; then
      return 1
    fi
    if [ "$idx" -eq "${#displays[@]}" ] 2>/dev/null; then
      return 1
    fi
    if [ "$idx" -eq "$((${#displays[@]} + 1))" ] 2>/dev/null; then
      return 2
    fi

    cmd="${INTERACTIVE_SAVED_COMMANDS[$idx]}"
    arg_count="${INTERACTIVE_SAVED_ARG_COUNTS[$idx]}"
    args_csv="${INTERACTIVE_SAVED_ARGS_CSV[$idx]}"
    _interactive_saved_parse_args "$arg_count" "$args_csv" || return 1
    if [ "${#INTERACTIVE_SAVED_ARGS[@]}" -gt 0 ] 2>/dev/null; then
      args=("${INTERACTIVE_SAVED_ARGS[@]}")
    else
      args=()
    fi
    display="$(_interactive_saved_command_display "$cmd" "$arg_count" "$args_csv" "")"
    favorite_label="Add to favorites"
    if interactive_favorite_has_entry "$cmd" "$arg_count" "$args_csv"; then
      favorite_label="Remove from favorites"
    fi

    choose_option_with_context_status choose_status action_idx "saved-command-list" "Saved command\n${display}" "Run command" "$favorite_label" "Back" "Quit"
    if [ "$choose_status" -ne 0 ]; then
      continue
    fi
    case "$action_idx" in
    0)
      if [ "${#args[@]}" -gt 0 ]; then
        interactive_picker_run_saved_command "$cmd" "${args[@]}"
      else
        interactive_picker_run_saved_command "$cmd"
      fi
      return $?
      ;;
    1)
      if [ "$favorite_label" = "Remove from favorites" ]; then
        interactive_unfavorite_command "$cmd" "$arg_count" "$args_csv" || return 1
      else
        interactive_favorite_command "$cmd" "$arg_count" "$args_csv" || return 1
      fi
      if [ "$source_label" = "favorites" ]; then
        interactive_load_favorite_commands || return 1
        _interactive_saved_fill_displays
        if [ "${#INTERACTIVE_SAVED_DISPLAYS[@]}" -gt 0 ] 2>/dev/null; then
          displays=("${INTERACTIVE_SAVED_DISPLAYS[@]}")
        else
          displays=()
        fi
        [ "${#displays[@]}" -gt 0 ] || return 1
      fi
      continue
      ;;
    2)
      continue
      ;;
    *)
      return 2
      ;;
    esac
  done
}

function interactive_picker_recent_commands() {
  interactive_picker_choose_saved_entry "Recent commands" "recent"
}

function interactive_picker_favorite_commands() {
  interactive_picker_choose_saved_entry "Favorites" "favorites"
}
