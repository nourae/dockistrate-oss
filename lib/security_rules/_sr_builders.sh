# shellcheck shell=bash

function _generate_security_rule_line() {
  local domain="$1" selector="$2" cond="$3" value="$4" code="$5" reason="${6:--}" loc="${7:-auto}" seed="${8:-}"
  local hv="" esc="" d="" f="" p="" rule_var=""
  local esc_reason="$reason" esc_loc="$loc"
  _sr_next_rule_var rule_var "$seed"
  _sr_selector_to_var "$selector" hv _
  esc="$(_escape_nginx_value "$value")"
  esc_reason="$(_escape_nginx_value "$esc_reason")"
  esc_loc="$(_escape_nginx_value "$esc_loc")"
  local sep=$'\x1f' expr
  expr="$(_sr_exprs "$cond" "$esc")" || return 1
  IFS=$sep read -r d f p <<<"$expr"
  printf 'set $%s_m 0; if ($host = %s) { set $%s_m 1; } ' "$rule_var" "$domain" "$rule_var"
  printf 'set $%s_p1 0; if (%s %s) { set $%s_p1 1; } ' "$rule_var" "$hv" "$f" "$rule_var"
  printf 'set $%s_tmp "$%s_m$%s_p1"; if ($%s_tmp = "11") { set $dockistrate_rule_reason "%s"; set $dockistrate_rule_loc "%s"; return %s; }\n' "$rule_var" "$rule_var" "$rule_var" "$rule_var" "$esc_reason" "$esc_loc" "$code"
}

function _generate_security_rule_multi_line() {
  local type="$1"
  shift
  local domain="$1"
  shift
  local code="$1"
  shift
  local reason="${1:--}"
  shift
  local loc="${1:-auto}"
  shift
  local seed=""
  if (($# % 3 == 1)); then
    seed="$1"
    shift
  fi
  local rule_var=""
  local esc_reason="$(_escape_nginx_value "$reason")" esc_loc="$(_escape_nginx_value "$loc")"
  _sr_next_rule_var rule_var "$seed"
  (($# % 3 == 0)) || return 1
  local n=$(($# / 3))
  ((n >= 2 && n <= 10)) || return 1
  local i idx=0 host_part="" or_part="" and_part="" concat="" ones="" fail_part=""
  printf -v host_part ' set $%s_m 0; if ($host = %s) { set $%s_m 1; }' "$rule_var" "$domain" "$rule_var"
  printf -v fail_part ' set $%s_fail 0; if ($%s_m = 1) { set $%s_fail 1; }' "$rule_var" "$rule_var" "$rule_var"
  for ((i = 1; i <= n; i++)); do
    local h="${@:$((idx + 1)):1}"
    local c="${@:$((idx + 2)):1}"
    local v="${@:$((idx + 3)):1}"
    idx=$((idx + 3))
    local hv="" esc="" d="" f="" p=""
    _sr_selector_to_var "$h" hv _
    esc="$(_escape_nginx_value "$v")"
    local sep=$'\x1f' expr
    expr="$(_sr_exprs "$c" "$esc")" || return 1
    IFS=$sep read -r d f p <<<"$expr" || return 1
    if [[ "$type" == "or" ]]; then
      printf -v or_part '%s if (%s %s) { set $%s_pass 1; }' "$or_part" "$hv" "$p" "$rule_var"
    else
      printf -v and_part '%s set $%s_p%d 0; if (%s %s) { set $%s_p%d 1; }' "$and_part" "$rule_var" "$i" "$hv" "$p" "$rule_var" "$i"
      printf -v concat '%s$%s_p%d' "$concat" "$rule_var" "$i"
      ones+="1"
    fi
  done
  if [[ "$type" == "or" ]]; then
    printf 'set $%s_pass 0;%s%s%s if ($%s_pass = 1) { set $%s_fail 0; } if ($%s_fail = 1) { set $dockistrate_rule_reason "%s"; set $dockistrate_rule_loc "%s"; return %s; }\n' \
      "$rule_var" "$host_part" "$or_part" "$fail_part" "$rule_var" "$rule_var" "$rule_var" "$esc_reason" "$esc_loc" "$code"
  else
    printf '%s%s%s set $%s_tmp "%s"; if ($%s_tmp = "%s") { set $%s_fail 0; } if ($%s_fail = 1) { set $dockistrate_rule_reason "%s"; set $dockistrate_rule_loc "%s"; return %s; }\n' \
      "$host_part" "$and_part" "$fail_part" "$rule_var" "$concat" "$rule_var" "$ones" "$rule_var" "$rule_var" "$esc_reason" "$esc_loc" "$code"
  fi
}

function _persisted_acl_error() {
  local line_no="$1" target_domain="$2" reason="$3"
  echo "[Error] Invalid persisted ACL rule at line ${line_no} for domain '${target_domain}': ${reason}" >&2
}

function _persisted_acl_cidr_error() {
  local line_no="$1" target_domain="$2" target_scope="$3" target_ip="$4"
  _persisted_acl_error "$line_no" "$target_domain" "CIDR values are not supported for ACL scope '${target_scope}': ${target_ip}"
}

function _persisted_acl_invalid_ip_error() {
  local line_no="$1" target_domain="$2" target_scope="$3" target_action="$4" target_ip="$5"
  _persisted_acl_error "$line_no" "$target_domain" "Invalid IP/CIDR for ACL scope '${target_scope}' action '${target_action}': ${target_ip}"
}

function _persisted_acl_invalid_code_error() {
  local line_no="$1" target_domain="$2" target_scope="$3" target_action="$4" target_code="$5"
  _persisted_acl_error "$line_no" "$target_domain" "Invalid status code for ACL scope '${target_scope}' action '${target_action}': ${target_code}"
}

function _persisted_acl_validate_row() {
  local line_no="$1" target_domain="$2" target_scope="$3" target_action="$4" target_ip="$5" target_code="${6:-}" target_mode="${7:-http}"

  if [ -n "$target_code" ] && ! is_status_code "$target_code"; then
    _persisted_acl_invalid_code_error "$line_no" "$target_domain" "$target_scope" "$target_action" "$target_code"
    return 1
  fi

  case "$target_mode" in
  http | stream)
    case "$target_scope" in
    l7)
      if ! is_valid_ip_or_cidr "$target_ip"; then
        _persisted_acl_invalid_ip_error "$line_no" "$target_domain" "$target_scope" "$target_action" "$target_ip"
        return 1
      fi
      ;;
    l3 | both)
      if is_valid_ipv4 "$target_ip"; then
        return 0
      fi
      if _sr_is_cidr_token "$target_ip"; then
        _persisted_acl_cidr_error "$line_no" "$target_domain" "$target_scope" "$target_ip"
      else
        _persisted_acl_invalid_ip_error "$line_no" "$target_domain" "$target_scope" "$target_action" "$target_ip"
      fi
      return 1
      ;;
    *)
      _persisted_acl_error "$line_no" "$target_domain" "Invalid ACL scope '${target_scope}'"
      return 1
      ;;
    esac
    ;;
  *)
    _persisted_acl_error "$line_no" "$target_domain" "Invalid ACL validation mode '${target_mode}'"
    return 1
    ;;
  esac

  return 0
}

# Build nginx include from DB

function _build_security_ip_for_domain() {
  local domain="$1"
  local default_status policy_l7 policy_l3
  policy_l7="$(get_backend_acl_policy "$domain")"
  # Unified ACL policy: L3 uses the same policy value
  policy_l3="$(get_backend_acl_policy "$domain")"
  default_status="$(get_backend_acl_status "$domain")"

  # Gather IP rules for this domain (declare as arrays for Bash 3 compatibility with set -u)
  local -a l7_allow=() l7_deny=() l3_allow=() l3_deny=()
  local -a l7_deny_code=() l3_deny_code=()

  # Helper function to collect IP rules for a specific domain.
  # Note: This function intentionally modifies the parent scope arrays
  # (l7_allow, l7_deny, l3_allow, l3_deny, l7_deny_code, l3_deny_code)
  # to allow reuse for both the domain itself and inherited rules.
  _collect_ip_rules_for() {
    local target_d="$1"
    if [ -f "$SECURITY_IP_RULES_DB" ]; then
      local enabled d a1 a2 a3 a4 line="" line_no=0
      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))
        [ "$line_no" -eq 1 ] && continue
        csv_parse_line "$line" || continue
        [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
        enabled="${CSV_FIELDS[0]-}"
        d="${CSV_FIELDS[1]-}"
        a1="${CSV_FIELDS[2]-}"
        a2="${CSV_FIELDS[3]-}"
        a3="${CSV_FIELDS[4]-}"
        a4="${CSV_FIELDS[5]-}"
        [ "$enabled" = "enabled" ] && continue
        [ "$enabled" = "1" ] || continue
        [ -z "$d" ] && continue
        d="$(normalize_domain "$d")"
        [ "$d" != "$target_d" ] && continue
        local scope action ip code
        scope="$a1"
        action="$a2"
        ip="$a3"
        code="$a4"
        case "$scope" in
        l7 | L7) scope="l7" ;;
        l3 | L3) scope="l3" ;;
        both | BOTH | Both) scope="both" ;;
        *) continue ;;
        esac
        case "$action" in allow | deny) ;; *) continue ;; esac
        _persisted_acl_validate_row "$line_no" "$target_d" "$scope" "$action" "$ip" "$code" "http" || return 1
        if [ "$scope" = "l7" ] || [ "$scope" = "both" ]; then
          if [ "$action" = "allow" ]; then
            l7_allow+=("$ip")
          else
            l7_deny+=("$ip")
            l7_deny_code+=("$code")
          fi
        fi
        if [ "$scope" = "l3" ] || [ "$scope" = "both" ]; then
          if [ "$action" = "allow" ]; then
            l3_allow+=("$ip")
          else
            l3_deny+=("$ip")
            l3_deny_code+=("$code")
          fi
        fi
      done <"$SECURITY_IP_RULES_DB"
    fi
  }

  # Collect rules for this domain
  _collect_ip_rules_for "$domain" || return 1

  # For dedicated hosts, inherit rules from target domain if:
  # 1. No explicit rules exist for the dedicated host
  # 2. Inheritance is enabled for ACL
  # This uses an all-or-nothing approach: if ANY explicit rule exists for the dedicated
  # host, no inheritance occurs. This ensures that dedicated hosts with partial explicit
  # rules have full control over their ACL behavior.
  local target_domain
  target_domain="$(backend_for_dedicated_host "$domain")"
  if [ -n "$target_domain" ] && [ ${#l7_allow[@]} -eq 0 ] && [ ${#l7_deny[@]} -eq 0 ] && [ ${#l3_allow[@]} -eq 0 ] && [ ${#l3_deny[@]} -eq 0 ]; then
    # Check if inheritance is enabled (defaults to yes if function not available)
    local should_inherit="yes"
    if command -v should_inherit_acl >/dev/null 2>&1; then
      should_inherit_acl "$domain" && should_inherit="yes" || should_inherit="no"
    fi
    if [ "$should_inherit" = "yes" ]; then
      _collect_ip_rules_for "$target_domain" || return 1
    fi
  fi

  # L7 explicit denies should run before deny/all return paths.
  _render_l7_deny_rules() {
    local i ip code
    for i in "${!l7_deny[@]}"; do
      ip="${l7_deny[$i]}"
      code="${l7_deny_code[$i]:-$default_status}"
      if [ "$code" = "403" ]; then
        echo "deny ${ip};"
      else
        if is_valid_ipv4 "$ip"; then
          echo "if (\$remote_addr = ${ip}) { return ${code}; }"
        else
          echo "# Note: CIDR ${ip} deny uses 403 only; falling back to deny directive."
          echo "deny ${ip};"
        fi
      fi
    done
  }

  _render_l3_deny_rules() {
    local i ip code
    for i in "${!l3_deny[@]}"; do
      ip="${l3_deny[$i]}"
      code="${l3_deny_code[$i]:-$default_status}"
      echo "if (\$realip_remote_addr = ${ip}) { return ${code}; }"
    done
  }

  # L7 policy
  if [ "$policy_l7" = "deny" ]; then
    if [ "$default_status" = "403" ]; then
      local ip
      local has_allow_all=0
      for ip in ${l7_allow[@]+"${l7_allow[@]}"}; do
        if is_valid_ipv4 "$ip"; then
          echo "allow ${ip};"
        elif is_valid_cidr "$ip"; then
          if _sr_is_cidr_all "$ip"; then
            has_allow_all=1
          else
            echo "allow ${ip};"
          fi
        fi
      done

      if [ ${#l7_deny[@]} -gt 0 ]; then
        _render_l7_deny_rules
      fi

      if [ "$has_allow_all" -eq 1 ]; then
        echo "allow all;"
      fi
      echo "deny all;"
    else
      local var="sr_${RANDOM}_l7_allow" ip
      local has_allow_all=0
      echo "set \$${var} 0;"
      for ip in ${l7_allow[@]+"${l7_allow[@]}"}; do
        if is_valid_ipv4 "$ip"; then
          echo "if (\$remote_addr = ${ip}) { set \$${var} 1; }"
        elif _sr_is_cidr_all "$ip"; then
          has_allow_all=1
        else
          echo "# Note: CIDR ${ip} cannot be evaluated for non-403 status; not matched here."
        fi
      done
      if [ "$has_allow_all" -eq 1 ]; then
        echo "set \$${var} 1;"
      fi

      if [ ${#l7_deny[@]} -gt 0 ]; then
        _render_l7_deny_rules
      fi

      echo "if (\$${var} = 0) { return ${default_status}; }"
    fi
  elif [ ${#l7_deny[@]} -gt 0 ]; then
    _render_l7_deny_rules
  fi

  # L3 policy (based on $realip_remote_addr)
  if [ "$policy_l3" = "deny" ]; then
    local var3="sr_${RANDOM}_l3_allow"
    echo "set \$${var3} 0;"
    local i ip
    for i in "${!l3_allow[@]}"; do
      ip="${l3_allow[$i]}"
      echo "if (\$realip_remote_addr = ${ip}) { set \$${var3} 1; }"
    done

    if [ ${#l3_deny[@]} -gt 0 ]; then
      _render_l3_deny_rules || return 1
    fi

    echo "if (\$${var3} = 0) { return ${default_status}; }"
  elif [ ${#l3_deny[@]} -gt 0 ]; then
    _render_l3_deny_rules || return 1
  fi
}

#--------------------------------------
# Unified ACL policy and status (global + per-backend)
#--------------------------------------

function _build_security_ip_stream_for_domain() {
  local domain="$1"
  local policy
  policy="$(get_backend_acl_policy "$domain")"

  # Gather IP rules for this domain (Bash 3-compatible arrays).
  # Stream ACLs use client IP only, so l7/l3/both all map to the same checks.
  local -a allow=() deny=()
  if [ -f "$SECURITY_IP_RULES_DB" ]; then
    local enabled d a1 a2 a3 a4 line="" line_no=0
    while IFS= read -r line || [ -n "$line" ]; do
      line_no=$((line_no + 1))
      [ "$line_no" -eq 1 ] && continue
      csv_parse_line "$line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
      enabled="${CSV_FIELDS[0]-}"
      d="${CSV_FIELDS[1]-}"
      a1="${CSV_FIELDS[2]-}"
      a2="${CSV_FIELDS[3]-}"
      a3="${CSV_FIELDS[4]-}"
      a4="${CSV_FIELDS[5]-}"
      [ "$enabled" = "enabled" ] && continue
      [ "$enabled" = "1" ] || continue
      [ -z "$d" ] && continue
      d="$(normalize_domain "$d")"
      [ "$d" != "$domain" ] && continue
      local scope action ip
      scope="$a1"
      action="$a2"
      ip="$a3"
      case "$scope" in
      l7 | L7) scope="l7" ;;
      l3 | L3) scope="l3" ;;
      both | BOTH | Both) scope="both" ;;
      *) continue ;;
      esac
      case "$action" in allow | deny) ;; *) continue ;; esac
      _persisted_acl_validate_row "$line_no" "$domain" "$scope" "$action" "$ip" "$a4" "stream" || return 1
      if [ "$action" = "allow" ]; then
        allow+=("$ip")
      else
        deny+=("$ip")
      fi
    done <"$SECURITY_IP_RULES_DB"
  fi

  # Stream ACLs use allow/deny directives only (no per-rule status codes).
  if [ "$policy" = "deny" ]; then
    local ip
    local has_allow_all=0
    for ip in ${allow[@]+"${allow[@]}"}; do
      if is_valid_ipv4 "$ip"; then
        echo "allow ${ip};"
      elif is_valid_cidr "$ip"; then
        if _sr_is_cidr_all "$ip"; then
          has_allow_all=1
        else
          echo "allow ${ip};"
        fi
      fi
    done
    # Explicit denies should be evaluated before catch-all rules.
    if [ ${#deny[@]} -gt 0 ]; then
      for ip in ${deny[@]+"${deny[@]}"}; do
        echo "deny ${ip};"
      done
    fi
    if [ "$has_allow_all" -eq 1 ]; then
      echo "allow all;"
    fi
    echo "deny all;"
  else
    # When policy is not "deny", only explicit denies apply.
    if [ ${#deny[@]} -gt 0 ]; then
      local ip
      for ip in ${deny[@]+"${deny[@]}"}; do
        echo "deny ${ip};"
      done
    fi
  fi
}

function _sr_is_cidr_all() {
  local token="${1:-}"
  [ -n "$token" ] || return 1
  local base prefix
  base="${token%/*}"
  prefix="${token#*/}"

  [ "$base" = "0.0.0.0" ] || return 1
  [ -n "$prefix" ] || return 1
  [ "$prefix" -eq 0 ] 2>/dev/null || return 1

  return 0
}
