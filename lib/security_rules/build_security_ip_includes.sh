# shellcheck shell=bash
if ! declare -F __dockistrate_security_rules_loaded >/dev/null 2>&1; then
  # Support direct sourcing of this entrypoint without requiring lib/security_rules.sh first.
  # shellcheck source=../security_rules.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/security_rules.sh"
fi

function build_security_ip_includes() {
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
  # Also include dedicated hosts which have their own server blocks
  local aliases_file
  aliases_file="$(backend_aliases_file)"
  if [ -f "$aliases_file" ]; then
    local alias_line="" alias_line_no=0
    while IFS= read -r alias_line || [ -n "$alias_line" ]; do
      alias_line_no=$((alias_line_no + 1))
      [ "$alias_line_no" -eq 1 ] && continue
      csv_parse_line "$alias_line" || continue
      [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_ALIASES_COLS" ] || continue
      [ "${CSV_FIELDS[0]-}" = "dedicated" ] || continue
      [ -n "${CSV_FIELDS[1]-}" ] || continue
      domains_lines+="$(normalize_domain "${CSV_FIELDS[1]}")"$'\n'
    done <"$aliases_file"
  fi
  domains="$(printf '%s' "$domains_lines" | awk 'NF > 0' | sort -u)"
  local d
  for d in $domains; do
    [ -z "$d" ] && continue
    local f_http="${SECURITY_IP_DIR}/$(sanitize_domain_name "$d").inc"
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$f_http" "security ip include file" || return 1
    fi
    : >"$f_http"
    if ! _build_security_ip_for_domain "$d" >>"$f_http"; then
      return 1
    fi
    local f_stream="${SECURITY_IP_STREAM_DIR}/$(sanitize_domain_name "$d").inc"
    if declare -F runtime_state_path_guard_if_declared >/dev/null 2>&1; then
      runtime_state_path_guard_if_declared "$f_stream" "stream security ip include file" || return 1
    fi
    : >"$f_stream"
    if ! _build_security_ip_stream_for_domain "$d" >>"$f_stream"; then
      return 1
    fi
  done
}
