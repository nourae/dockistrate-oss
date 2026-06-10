# shellcheck shell=bash

# Some unit tests source this file directly without loading lib/utils/state_csv.sh.
# Provide local fallbacks to keep strict-mode reads safe in that context.
: "${STATE_SECURITY_RULES_HEADER:=enabled,domain,mode,status_code,condition_count,selector_1,name_1,condition_1,value_1,selector_2,name_2,condition_2,value_2,selector_3,name_3,condition_3,value_3,selector_4,name_4,condition_4,value_4,selector_5,name_5,condition_5,value_5,selector_6,name_6,condition_6,value_6,selector_7,name_7,condition_7,value_7,selector_8,name_8,condition_8,value_8,selector_9,name_9,condition_9,value_9,selector_10,name_10,condition_10,value_10,reason,source_location}"
: "${STATE_SECURITY_RULES_COLS:=47}"
: "${STATE_SECURITY_IP_RULES_HEADER:=enabled,domain,scope,action,ip_value,status_code}"
: "${STATE_SECURITY_IP_RULES_COLS:=6}"
: "${STATE_BACKEND_PORTS_HEADER:=record_type,domain,backend_upstream,network,path_prefix,header_set,listen_port,upstream_port,protocol,certificate_ref,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc,path_match,path_priority,path_target,path_rewrite,reason,source_location}"
: "${STATE_BACKEND_PORTS_COLS:=21}"

function _sr_ensure_rules_db() {
  csv_require_header "$SECURITY_RULES_DB" "$STATE_SECURITY_RULES_HEADER"
}

function _sr_ensure_ip_db() {
  csv_require_header "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER"
}

function _sr_load_line() {
  local id="$1"
  local line_no=0
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ]; then
    return 1
  fi
  _sr_ensure_rules_db || return 1
  line_no=$((id + 1))
  sed -n "${line_no}p" "$SECURITY_RULES_DB" 2>/dev/null || true
}

function _sr_ip_load_line() {
  local id="$1"
  local line_no=0
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ]; then
    return 1
  fi
  _sr_ensure_ip_db || return 1
  line_no=$((id + 1))
  sed -n "${line_no}p" "$SECURITY_IP_RULES_DB" 2>/dev/null || true
}


function _sr_write_db_line() {
  local enabled="${1:-}" domain="${2:-}" mode="${3:-}" code="${4:-}" n="${5:-0}"
  local reason="-" loc="auto"
  local -a fields=() remaining=() cond_fields=()
  local expected_cond_fields=0

  shift 5 || true
  remaining=("$@")

  if [[ "$n" =~ ^[0-9]+$ ]]; then
    expected_cond_fields=$((n * 4))
  fi

  # Support both call shapes:
  # 1) legacy: _sr_write_db_line ... <cond_fields...>
  # 2) current: _sr_write_db_line ... <reason> <loc> <cond_fields...>
  if [ "${#remaining[@]}" -eq "$expected_cond_fields" ]; then
    cond_fields=("${remaining[@]}")
  elif [ "${#remaining[@]}" -ge $((expected_cond_fields + 2)) ]; then
    reason="${remaining[0]:--}"
    loc="${remaining[1]:-auto}"
    if [ "$expected_cond_fields" -gt 0 ]; then
      cond_fields=("${remaining[@]:2:$expected_cond_fields}")
    fi
  else
    cond_fields=("${remaining[@]}")
  fi

  # Canonical schema:
  # enabled,domain,mode,status_code,condition_count,(selector_N,name_N,condition_N,value_N)x10,reason,source_location
  fields=("$enabled" "$domain" "$mode" "$code" "$n")
  if [ "${#cond_fields[@]}" -gt 0 ]; then
    fields+=("${cond_fields[@]}")
  fi
  while [ "${#fields[@]}" -lt 45 ]; do
    fields+=("")
  done
  if [ "${#fields[@]}" -gt 45 ]; then
    fields=("${fields[@]:0:45}")
  fi
  fields+=("$reason" "$loc")
  while [ "${#fields[@]}" -lt "$STATE_SECURITY_RULES_COLS" ]; do
    fields+=("")
  done
  if [ "${#fields[@]}" -gt "$STATE_SECURITY_RULES_COLS" ]; then
    fields=("${fields[@]:0:$STATE_SECURITY_RULES_COLS}")
  fi

  csv_join_row "${fields[@]}"
}


function _sr_delete_line() {
  local id="$1"
  local tmp_file=""
  local line_no=0
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ]; then
    return 1
  fi
  _sr_ensure_rules_db || return 1
  line_no=$((id + 1))
  make_temp_for_file tmp_file "$SECURITY_RULES_DB" || return 1
  if awk -v n="$line_no" 'NR!=n' "$SECURITY_RULES_DB" >"$tmp_file"; then
    finalize_temp_file "$SECURITY_RULES_DB" "$tmp_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

function _sr_ip_delete_line() {
  local id="$1"
  local tmp_file="" line_no=0
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ]; then
    return 1
  fi
  _sr_ensure_ip_db || return 1
  line_no=$((id + 1))
  make_temp_for_file tmp_file "$SECURITY_IP_RULES_DB" || return 1
  if awk -v n="$line_no" 'NR!=n' "$SECURITY_IP_RULES_DB" >"$tmp_file"; then
    finalize_temp_file "$SECURITY_IP_RULES_DB" "$tmp_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

# Unified add (1–10 conditions). When count>1, --mode and|or required.


function _sr_replace_line() {
  local id="$1" new="$2"
  local tmp_file=""
  local line_no=0
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ]; then
    return 1
  fi
  _sr_ensure_rules_db || return 1
  line_no=$((id + 1))
  make_temp_for_file tmp_file "$SECURITY_RULES_DB" || return 1
  if awk -v n="$line_no" -v r="$new" 'NR==n{$0=r}1' "$SECURITY_RULES_DB" >"$tmp_file"; then
    finalize_temp_file "$SECURITY_RULES_DB" "$tmp_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

function _sr_ip_replace_line() {
  local id="$1" new="$2"
  local tmp_file="" line_no=0
  if ! [[ "$id" =~ ^[0-9]+$ ]] || [ "$id" -lt 1 ]; then
    return 1
  fi
  _sr_ensure_ip_db || return 1
  line_no=$((id + 1))
  make_temp_for_file tmp_file "$SECURITY_IP_RULES_DB" || return 1
  if awk -v n="$line_no" -v r="$new" 'NR==n{$0=r}1' "$SECURITY_IP_RULES_DB" >"$tmp_file"; then
    finalize_temp_file "$SECURITY_IP_RULES_DB" "$tmp_file"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

function _sr_ip_move_line() {
  local from="$1" to="$2"
  local count line line_no tmp_file
  local -a rows=() reordered=()
  local from_idx to_idx moving i inserted=0

  _sr_ensure_ip_db || return 1
  count="$(csv_data_row_count "$SECURITY_IP_RULES_DB" "$STATE_SECURITY_IP_RULES_HEADER" 2>/dev/null || echo 0)"
  if [ "$count" -lt 1 ]; then
    return 1
  fi
  if [ "$from" -lt 1 ] || [ "$from" -gt "$count" ] || [ "$to" -lt 1 ] || [ "$to" -gt "$count" ]; then
    return 1
  fi

  line_no=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    rows+=("$line")
  done <"$SECURITY_IP_RULES_DB"

  from_idx=$((from - 1))
  to_idx=$((to - 1))
  moving="${rows[$from_idx]}"
  unset "rows[$from_idx]"
  rows=("${rows[@]}")

  for ((i = 0; i < ${#rows[@]}; i++)); do
    if [ "$i" -eq "$to_idx" ]; then
      reordered+=("$moving")
      inserted=1
    fi
    reordered+=("${rows[$i]}")
  done
  if [ "$inserted" -eq 0 ]; then
    reordered+=("$moving")
  fi

  make_temp_for_file tmp_file "$SECURITY_IP_RULES_DB" || return 1
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$tmp_file"
  for line in "${reordered[@]}"; do
    printf '%s\n' "$line" >>"$tmp_file"
  done
  finalize_temp_file "$SECURITY_IP_RULES_DB" "$tmp_file"
}


function _sr_rule_var_reserved() {
  local candidate="${1:-}"
  [ -n "$candidate" ] || return 1
  printf '%s\n' "${SR_RULE_VARS_EMITTED:-}" | grep -Fxq "$candidate"
}

function _sr_mark_rule_var_reserved() {
  local candidate="${1:-}"
  [ -n "$candidate" ] || return 1
  if [ -n "${SR_RULE_VARS_EMITTED:-}" ]; then
    SR_RULE_VARS_EMITTED+=$'\n'
  fi
  SR_RULE_VARS_EMITTED+="$candidate"
}

function _sr_hash_rule_seed() {
  local seed="${1:-}" checksum=""
  checksum="$(printf '%s' "$seed" | cksum | awk '{print $1}')"
  [ -n "$checksum" ] || return 1
  printf 'sr_%010d' "$checksum"
}

function _sr_next_rule_var() {
  local __out="${1:-}" seed="${2:-}" candidate="" base="" suffix=0
  [ -n "$__out" ] || return 1

  if [ -n "$seed" ]; then
    base="$(_sr_hash_rule_seed "$seed")" || return 1
    candidate="$base"
    while _sr_rule_var_reserved "$candidate"; do
      suffix=$((suffix + 1))
      candidate="${base}_${suffix}"
    done
    _sr_mark_rule_var_reserved "$candidate"
    printf -v "$__out" '%s' "$candidate"
    return 0
  fi

  printf -v "$__out" 'sr_%06d' "$SR_RULE_COUNTER"
  SR_RULE_COUNTER=$((SR_RULE_COUNTER + 1))
}


function _sr_assert_domain_exists() {
  local raw="$1"
  local d line="" line_no=0 found=0
  d="$(normalize_domain "$raw")"
  if [ ! -f "$BACKEND_PORTS_FILE" ]; then
    echo "[Error] Unknown domain '$raw' (no backend found)." >&2
    exit 1
  fi
  if ! csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"; then
    exit 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue
    csv_parse_line "$line" || continue
    [ "$CSV_FIELD_COUNT" -eq "$STATE_BACKEND_PORTS_COLS" ] || continue
    if [ "${CSV_FIELDS[0]}" = "backend" ] && [ "$(normalize_domain "${CSV_FIELDS[1]}")" = "$d" ]; then
      found=1
      break
    fi
  done <"$BACKEND_PORTS_FILE"
  if [ "$found" -eq 0 ]; then
    echo "[Error] Unknown domain '$raw' (no backend found)." >&2
    exit 1
  fi
}

# Numeric helper utilities -------------------------------------------------
