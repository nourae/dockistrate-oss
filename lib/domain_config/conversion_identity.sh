# shellcheck shell=bash

function _domain_config_rule_legacy_line() {
  local _dc_config="$1" _dc_domain="$2" _dc_rule_id="$3" enabled="$4" action="$5" mode="$6" status="$7" reason="$8" location="$9"
  local _dc_condition_count=0 i=0
  local -a _dc_conditions=() fields=()
  _domain_csv_read "$_dc_config/security_conditions.csv" _domain_config_compile_condition || return 1
  fields=("$enabled" "$_dc_domain" "$mode" "$status" "$_dc_condition_count")
  for ((i = 0; i < 40; i++)); do fields+=("${_dc_conditions[i]-}"); done
  fields+=("${reason:--}" "${location:-auto}")
  action="$(_sr_normalize_action "$action")" || return 1
  if [ "$STATE_SECURITY_RULES_COLS" -eq 48 ]; then fields+=("$action")
  elif [ "$STATE_SECURITY_RULES_COLS" -ne 47 ] || [ "$action" != require ]; then return 1; fi
  csv_join_row "${fields[@]}"
}

function _domain_config_old_rule() {
  shift 2
  local content=""
  content="$(_domain_config_rule_legacy_line "$_dc_old_config" "$_dc_old_domain" "$1" "$3" "$4" "$5" "$6" "$7" "$8")" || return 1
  _dc_old_ids+=("$1"); _dc_old_orders+=("$2"); _dc_old_contents+=("$content")
}

function _domain_config_old_acl() {
  shift 2
  local content=""
  content="$(csv_join_row "$3" "$_dc_old_domain" "$4" "$5" "$6" "$7")" || return 1
  _dc_old_ids+=("$1"); _dc_old_orders+=("$2"); _dc_old_contents+=("$content")
}

function _domain_config_collect_legacy_content() {
  shift
  local content=""
  content="$(csv_join_row "$@")" || return 1
  _dc_current_contents="${_dc_current_contents}${content}"$'\n'
  _dc_new_contents+=("$content")
}

function _domain_config_apply_identity_hint() {
  local family="$1" action="" from="${DOMAIN_CONFIG_IDENTITY_ARG1:-}" to="${DOMAIN_CONFIG_IDENTITY_ARG2:-}"
  local count="${#_dc_old_ids[@]}" actual="${#_dc_new_contents[@]}" i=0 position=0
  case "$family:${DOMAIN_CONFIG_MUTATION_COMMAND:-}" in
  rule:remove-security-rule | acl:remove-acl) action=remove ;;
  rule:move-security-rule | acl:move-acl-rule) action=move ;;
  rule:duplicate-security-rule) action=duplicate ;;
  rule:add-security-rule | acl:add-acl) action=append ;;
  rule:remove-all-security-rules | acl:remove-all-acl) action=clear ;;
  rule:update-security-rule | rule:set-security-rule-mode | rule:enable-security-rule | rule:disable-security-rule | \
    rule:enable-all-security-rules | rule:disable-all-security-rules | \
    acl:update-acl | acl:enable-acl | acl:disable-acl | acl:enable-all-acl | acl:disable-all-acl) action=keep ;;
  *) return 0 ;;
  esac
  case "$action" in
  remove | move)
    while [ "${from#0}" != "$from" ]; do from="${from#0}"; done
    _domain_csv_positive_integer "$from" && [ "$from" -le "$count" ] || return 1
    from=$((from - 1))
    ;;
  esac
  case "$action" in
  remove) [ "$actual" -eq "$((count - 1))" ] || return 1 ;;
  move)
    while [ "${to#0}" != "$to" ]; do to="${to#0}"; done
    _domain_csv_positive_integer "$to" && [ "$to" -le "$count" ] && [ "$actual" -eq "$count" ] || return 1
    to=$((to - 1))
    ;;
  duplicate) [ "$actual" -eq "$((count + 1))" ] || return 1 ;;
  append) [ "$actual" -ge "$count" ] || return 1 ;;
  clear) [ "$actual" -eq 0 ] || return 1 ;;
  keep) [ "$actual" -eq "$count" ] || return 1 ;;
  esac
  _dc_hint_applied=true
  [ "$action" != clear ] || return 0
  for ((i = 0; i < count; i++)); do
    position="${_dc_old_positions[i]}"
    case "$action" in
    remove)
      [ "$position" -ne "$from" ] || continue
      [ "$position" -lt "$from" ] || position=$((position - 1))
      ;;
    move)
      if [ "$position" -eq "$from" ]; then position="$to"
      elif [ "$from" -lt "$to" ] && [ "$position" -gt "$from" ] && [ "$position" -le "$to" ]; then position=$((position - 1))
      elif [ "$from" -gt "$to" ] && [ "$position" -ge "$to" ] && [ "$position" -lt "$from" ]; then position=$((position + 1))
      fi
      ;;
    esac
    _dc_export_ids_by_order[position]="${_dc_old_ids[i]}"
    _dc_used_ids="${_dc_used_ids}${_dc_old_ids[i]}"$'\n'
  done
}

function _domain_config_export_identity_prepare() {
  local family="$1" entry="" _dc_old_config="" _dc_old_domain="" root="${DOMAINS_DIR:-${STATE_DIR}/domains}"
  local i=0 j=0 rank=0 maximum=0 previous=0 reordered=false known_order=0 orders="" _dc_hint_applied=false
  local -a sorted_orders=() _dc_old_positions=()
  _dc_old_ids=(); _dc_old_orders=(); _dc_old_contents=()
  _dc_new_contents=(); _dc_export_ids_by_order=(); _dc_export_orders_by_order=()
  _dc_used_ids=$'\n'; _dc_current_contents=$'\n'
  for entry in "$root"/*; do
    [ -d "$entry/runtime/applied" ] || continue
    _dc_old_config="$entry/runtime/applied"; _dc_old_domain="${entry##*/}"
    if [ "$family" = rule ]; then
      _domain_csv_read "$_dc_old_config/security_rules.csv" _domain_config_old_rule || return 1
    else
      _domain_csv_read "$_dc_old_config/acl.csv" _domain_config_old_acl || return 1
    fi
  done
  if [ "$family" = rule ]; then
    _domain_config_legacy_read "$SECURITY_RULES_FILE" "$STATE_SECURITY_RULES_HEADER" _domain_config_collect_legacy_content || return 1
  else
    _domain_config_legacy_read "$SECURITY_IP_RULES_FILE" "$STATE_SECURITY_IP_RULES_HEADER" _domain_config_collect_legacy_content || return 1
  fi
  for ((i = 0; i < ${#_dc_old_orders[@]}; i++)); do
    [ "${_dc_old_orders[i]}" -le "$maximum" ] || maximum="${_dc_old_orders[i]}"
    rank=0
    for ((j = 0; j < ${#_dc_old_orders[@]}; j++)); do
      [ "${_dc_old_orders[j]}" -ge "${_dc_old_orders[i]}" ] || rank=$((rank + 1))
    done
    _dc_old_positions[i]="$rank"
  done
  for ((i = 0; i < ${#_dc_new_contents[@]}; i++)); do _dc_export_ids_by_order[i]=""; done
  _domain_config_apply_identity_hint "$family" || return 1
  # Reserve unchanged positions before matching moves. Otherwise editing A to
  # equal B's content would steal B's identity and rename the untouched row.
  for ((i = 0; i < ${#_dc_old_ids[@]}; i++)); do
    [ "$_dc_hint_applied" != true ] || break
    rank="${_dc_old_positions[i]}"
    if [ "$rank" -lt "${#_dc_new_contents[@]}" ] && [ "${_dc_old_contents[i]}" = "${_dc_new_contents[rank]}" ]; then
      _dc_export_ids_by_order[rank]="${_dc_old_ids[i]}"
      _dc_used_ids="${_dc_used_ids}${_dc_old_ids[i]}"$'\n'
    fi
  done
  # Match every moved row before assigning identities to edited/new rows.
  for ((i = 0; i < ${#_dc_new_contents[@]}; i++)); do
    [ "$_dc_hint_applied" != true ] || break
    [ -z "${_dc_export_ids_by_order[i]}" ] || continue
    for ((j = 0; j < ${#_dc_old_ids[@]}; j++)); do
      case "$_dc_used_ids" in *$'\n'"${_dc_old_ids[j]}"$'\n'*) continue ;; esac
      [ "${_dc_old_contents[j]}" = "${_dc_new_contents[i]}" ] || continue
      _dc_export_ids_by_order[i]="${_dc_old_ids[j]}"
      _dc_used_ids="${_dc_used_ids}${_dc_old_ids[j]}"$'\n'
      break
    done
  done
  for ((i = 0; i < ${#_dc_new_contents[@]}; i++)); do
    if [ -z "${_dc_export_ids_by_order[i]}" ]; then
      _domain_config_match_identity "$family" "$((i + 1))" || return 1
      _dc_export_ids_by_order[i]="$_dc_export_identity"
    else
      _dc_export_identity="${_dc_export_ids_by_order[i]}"
    fi
    known_order=0
    for ((j = 0; j < ${#_dc_old_ids[@]}; j++)); do
      if [ "${_dc_old_ids[j]}" = "$_dc_export_identity" ]; then known_order="${_dc_old_orders[j]}"; break; fi
    done
    if [ "$known_order" -gt 0 ]; then
      _dc_export_orders_by_order+=("$known_order")
    else
      maximum=$((maximum + 1)); known_order="$maximum"
      _dc_export_orders_by_order+=("$known_order")
    fi
    [ "$known_order" -gt "$previous" ] || reordered=true
    previous="$known_order"
  done
  if [ "$maximum" -gt 999999999 ]; then
    [ "${#_dc_export_orders_by_order[@]}" -le 999999999 ] || return 1
    for ((i = 0; i < ${#_dc_export_orders_by_order[@]}; i++)); do
      _dc_export_orders_by_order[i]="$((i + 1))"
    done
  elif [ "$reordered" = true ]; then
    orders="$(printf '%s\n' "${_dc_export_orders_by_order[@]}" | LC_ALL=C sort -n)" || return 1
    while IFS= read -r entry; do sorted_orders+=("$entry"); done <<<"$orders"
    for ((i = 0; i < ${#_dc_export_ids_by_order[@]}; i++)); do
      _dc_export_orders_by_order[i]="${sorted_orders[i]}"
    done
  fi
}

# Unchanged and moved rows were already reserved. An edited row can now retain
# the old ordinal's unused identity, even when its new content duplicates a row.
# Numeric public selectors still describe current global order, not these IDs.
function _domain_config_match_identity() {
  local family="$1" order="$2" i=0 id="" suffix=0 used=false
  for ((i = 0; i < ${#_dc_old_ids[@]}; i++)); do
    [ "${_dc_old_positions[i]}" -eq "$((order - 1))" ] || continue
    case "$_dc_used_ids" in *$'\n'"${_dc_old_ids[i]}"$'\n'*) continue ;; esac
    id="${_dc_old_ids[i]}"; break
  done
  if [ -z "$id" ]; then
    id="${family}-${order}"
    while :; do
      used=false
      for ((i = 0; i < ${#_dc_old_ids[@]}; i++)); do [ "${_dc_old_ids[i]}" != "$id" ] || used=true; done
      case "$_dc_used_ids" in *$'\n'"$id"$'\n'*) used=true ;; esac
      [ "$used" = true ] || break
      suffix=$((suffix + 1)); id="${family}-${order}-${suffix}"
    done
  fi
  _dc_used_ids="${_dc_used_ids}${id}"$'\n'
  _dc_export_identity="$id"
}

function _domain_config_export_identity() {
  local index=$((${2:-1} - 1))
  _dc_export_identity="${_dc_export_ids_by_order[index]}"
  _dc_export_order="${_dc_export_orders_by_order[index]}"
}

function _domain_config_export_path_identity_row() {
  shift 2
  if [ "$2" = "$_dc_path_port" ] && [ "$3" = "$_dc_path_prefix" ]; then _dc_path_identity="$1"; fi
  _dc_old_path_ids="${_dc_old_path_ids}$1"$'\n'
}

function _domain_config_export_path_identity() {
  local _dc_path_port="$1" _dc_path_prefix="$2" _dc_path_identity="" _dc_old_path_ids=$'\n' suffix=0 id=""
  case "${DOMAIN_CONFIG_MUTATION_COMMAND:-}" in
  update-port)
    if [ "$_dc_domain" = "${_UPM_PATH_REWRITE_DOMAIN:-}" ] &&
      [ "$_dc_path_port" = "${_UPM_PATH_REWRITE_NEW_PORT:-}" ] && [ -n "${_UPM_PATH_REWRITE_OLD_PORT:-}" ]; then
      _dc_path_port="$_UPM_PATH_REWRITE_OLD_PORT"
    fi
    ;;
  update-path-option)
    if [ "${_UPO_REWRITE_APPLIED:-}" = yes ] && [ "$_dc_domain" = "${_UPO_REWRITE_DOMAIN:-}" ] &&
      [ "$_dc_path_port" = "${_UPO_REWRITE_NEW_PORT:-}" ] && [ "$_dc_path_prefix" = "${_UPO_REWRITE_NEW_PATH:-}" ]; then
      _dc_path_port="$_UPO_REWRITE_OLD_PORT"; _dc_path_prefix="$_UPO_REWRITE_OLD_PATH"
    fi
    ;;
  esac
  _domain_csv_read "${DOMAINS_DIR:-${STATE_DIR}/domains}/${_dc_domain}/runtime/applied/paths.csv" _domain_config_export_path_identity_row || return 1
  id="$_dc_path_identity"
  if [ -z "$id" ]; then
    id="path-${_dc_path_count}"
    while :; do
      case "$_dc_old_path_ids" in
      *$'\n'"$id"$'\n'*) suffix=$((suffix + 1)); id="path-${_dc_path_count}-${suffix}" ;;
      *) break ;;
      esac
    done
  fi
  _dc_export_path_id="$id"
}
