# shellcheck shell=bash

# Keep the selected row's values explicit while collecting CLI-compatible flags.
function _acl_prompt_current_choice() {
  local output="$1" prompt="$2" current="$3" choices="$4" selected=""
  local options=""
  options="$(csv_join_row __KEEP__ "Keep current: $current")"
  [ -z "$choices" ] || options+=$'\n'"$choices"
  _sr_prompt_choice selected "$prompt" "$options" || return 1
  [ "$selected" != __KEEP__ ] || selected="$current"
  printf -v "$output" '%s' "$selected"
}

function prompt_args_handle_update_acl_interactive() {
  [ "${INTERACTIVE:-false}" = true ] || return 2
  local cmd="$1" choices="" id="" row=""
  choices="$(get_arg_choices "$cmd" id)"
  [ -n "$choices" ] || { echo '[Info] No ACL rules configured.' >&2; return 1; }
  _sr_prompt_choice id 'Select ACL rule' "$choices" || return 1
  row="$(_sr_ip_load_line "$id")" || return 1
  csv_parse_line "$row" && [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || return 1
  local old_domain="${CSV_FIELDS[1]}" old_scope="${CSV_FIELDS[2]}" old_action="${CSV_FIELDS[3]}"
  local old_ip="${CSV_FIELDS[4]}" old_code="${CSV_FIELDS[5]}"
  local domain="" scope="" action="" ip="" code="$old_code" entered=""

  choices="$(get_arg_choices "$cmd" domain)"
  _acl_prompt_current_choice domain Domain "$old_domain" "$choices" || return 1
  choices="$(csv_join_row l7 'Layer 7 (client IP; CIDR supported)')"$'\n'
  choices+="$(csv_join_row l3 'Layer 3 (real peer IP; exact IPv4)')"$'\n'
  choices+="$(csv_join_row both 'Apply to L7 and L3 (exact IPv4)')"
  _acl_prompt_current_choice scope Scope "$old_scope" "$choices" || return 1
  _acl_prompt_current_choice action Action "$old_action" $'allow|Allow\ndeny|Deny' || return 1

  while true; do
    read_with_editing "IP or CIDR [$old_ip]: " ip "$old_ip"
    [ "${READ_WITH_EDITING_CANCEL_REASON:-}" != eof ] || return 1
    is_back_input "$ip" && return 1
    if ! is_valid_ip_or_cidr "$ip"; then
      echo '[Error] Enter one valid IPv4 address or CIDR.' >&2
      continue
    fi
    if [ "$scope" != l7 ] && _sr_is_cidr_token "$ip"; then
      echo "[Error] Scope '$scope' requires an exact IPv4 address." >&2
      continue
    fi
    break
  done
  if [ "$action" = deny ]; then
    while true; do
      read_with_editing "Status code (blank keeps ${old_code:-inherited default}; '-' clears): " entered
      [ "${READ_WITH_EDITING_CANCEL_REASON:-}" != eof ] || return 1
      is_back_input "$entered" && return 1
      case "$entered" in
      '') code="$old_code" ;;
      -) code="" ;;
      *)
        if ! is_status_code "$entered"; then
          echo '[Error] Enter a valid HTTP status code.' >&2
          continue
        fi
        code="$entered"
        ;;
      esac
      _sr_validate_acl_cidr_deny_status "$scope" "$action" "$ip" "$code" || continue
      break
    done
  fi
  local -a args=("$id")
  [ "$domain" = "$old_domain" ] || args+=(--domain "$domain")
  [ "$scope" = "$old_scope" ] || args+=(--scope "$scope")
  [ "$action" = "$old_action" ] || args+=(--action "$action")
  [ "$ip" = "$old_ip" ] || args+=(--ip "$ip")
  [ "$code" = "$old_code" ] || args+=(--code "$code")
  if [ "${#args[@]}" -eq 1 ]; then
    echo "[Info] No changes selected for ACL rule $id."
    return 1
  fi
  PROMPT_ARGS_COLLECTED=("${args[@]}")
}
