# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function build_security_ip_includes() {
  # Keep ACL allocation independent of request-rule names and prior renders.
  local SR_RULE_VARS_EMITTED="" acl_var_base=""
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" || return 1
  fi
  mkdir -p "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR"
  if declare -F runtime_state_paths_guard_if_declared >/dev/null 2>&1; then
    runtime_state_paths_guard_if_declared "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" || return 1
  fi
  # Collect candidate domains from backends and explicit IP rule entries
  local domains=""
  local domains_lines=""
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    local bp_line="" bp_line_no=0
    while IFS= read -r bp_line || [ -n "$bp_line" ]; do
      bp_line_no=$((bp_line_no + 1))
      [ "$bp_line_no" -eq 1 ] && continue
      state_backend_ports_parse_line "$bp_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
      [ "${STATE_BP_RECORD_TYPE:-}" = "backend" ] || continue
      [ -n "${STATE_BP_DOMAIN:-}" ] || continue
      domains_lines+="$(normalize_domain "$STATE_BP_DOMAIN")"$'\n'
    done <"$BACKEND_PORTS_FILE"
  fi
  if [ -f "$SECURITY_IP_RULES_DB" ]; then
    local sec_line="" sec_line_no=0
    while IFS= read -r sec_line || [ -n "$sec_line" ]; do
      sec_line_no=$((sec_line_no + 1))
      [ "$sec_line_no" -eq 1 ] && continue
      csv_parse_line "$sec_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_SECURITY_IP_RULES_COLS" ] || continue
      [ -n "${CSV_FIELDS[1]-}" ] || continue
      domains_lines+="$(normalize_domain "${CSV_FIELDS[1]}")"$'\n'
    done <"$SECURITY_IP_RULES_DB"
  fi
  # Include aliases with policy/status-only overrides as well as dedicated hosts.
  local aliases_file
  aliases_file="$(backend_aliases_file)"
  if [ -f "$aliases_file" ]; then
    local alias_line="" alias_line_no=0
    while IFS= read -r alias_line || [ -n "$alias_line" ]; do
      alias_line_no=$((alias_line_no + 1))
      [ "$alias_line_no" -eq 1 ] && continue
      csv_parse_line "$alias_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || continue
      case "${CSV_FIELDS[0]-}" in alias | dedicated) ;; *) continue ;; esac
      [ -n "${CSV_FIELDS[1]-}" ] || continue
      domains_lines+="$(normalize_domain "${CSV_FIELDS[1]}")"$'\n'
    done <"$aliases_file"
  fi
  domains="$(printf '%s' "$domains_lines" | awk 'NF > 0' | sort -u)"
  local d
  for d in $domains; do
    [ -z "$d" ] && continue
    local f_http="${SECURITY_IP_DIR}/$(sanitize_domain_name "$d").inc"
    local f_stream="${SECURITY_IP_STREAM_DIR}/$(sanitize_domain_name "$d").inc"
    local alias_target="" alias_acl_status=0
    alias_target="$(backend_for_alias "$d")" || return 1
    if [ -n "$alias_target" ]; then
      # Ordinary aliases have no stream listener. Drop stale files when the last
      # explicit ACL is disabled/removed and the alias rejoins its primary block.
      safe_rm_f "$f_stream" "$SECURITY_IP_STREAM_DIR" || return 1
      _alias_has_explicit_acl "$d" || alias_acl_status=$?
      case "$alias_acl_status" in
      0) ;;
      1) safe_rm_f "$f_http" "$SECURITY_IP_DIR" || return 1; continue ;;
      *) return 1 ;;
      esac
      # Removing the last own rule can expose inherited CIDR allows while an
      # alias status override remains. Reject unsupported effective policy so
      # the enclosing transaction restores the previous usable configuration.
      local alias_policy alias_status
      alias_policy="$(get_backend_acl_policy "$d")" || return 1
      alias_status="$(get_backend_acl_status "$d")" || return 1
      _sr_validate_acl_cidr_mode_for_domain "$d" "$alias_policy" "$alias_status" || return 1
    fi
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$f_http" "security ip include file" || return 1
    fi
    : >"$f_http"
    _sr_next_rule_var acl_var_base "acl:$d" || return 1
    if ! _build_security_ip_for_domain "$d" "$acl_var_base" >>"$f_http"; then
      return 1
    fi
    [ -z "$alias_target" ] || continue
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$f_stream" "stream security ip include file" || return 1
    fi
    : >"$f_stream"
    if ! _build_security_ip_stream_for_domain "$d" >>"$f_stream"; then
      return 1
    fi
  done
}
