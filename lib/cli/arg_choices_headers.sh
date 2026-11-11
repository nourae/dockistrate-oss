# shellcheck shell=bash

function __arg_choices_headers_use_applied() {
  declare -F domain_config_active >/dev/null 2>&1 && domain_config_active
}

function _cli_header_emit_record() {
  shift 2
  if [ -n "${_cli_header_owner:-}" ]; then
    csv_join_row "$_cli_header_owner" "$@"
  else
    csv_join_row "$@"
  fi
}

# Header repair is available before runtime preparation. Read original applied
# rows directly: compiling them here would reject the conflict being repaired,
# and using the aggregate cache could show stale names or lose available owners.
function __arg_choices_backend_header_records() {
  local _cli_header_owner="" root="" source="" domains=""
  if __arg_choices_headers_use_applied; then
    root="$(domain_config_root)" || return 1
    domains="$(domain_config_list applied)" || return 1
    [ -n "$domains" ] || return 0
    while IFS= read -r _cli_header_owner; do
      source="$root/$_cli_header_owner/runtime/applied"
      _domain_config_dir_guard "$source" || return 1
      csv_read_records "$source/headers.csv" 'header_type,header_name,header_value' _cli_header_emit_record table || return 1
    done <<<"$domains"
  else
    csv_read_records "$BACKEND_HEADERS_FILE" "$STATE_BACKEND_HEADERS_HEADER" _cli_header_emit_record table
  fi
}

function __arg_choices_global_header_records() {
  local _cli_header_owner=""
  csv_read_records "$CUSTOM_HEADERS_FILE" "$STATE_CUSTOM_HEADERS_HEADER" _cli_header_emit_record table
}

function __arg_choices_header_domains() {
  local domain="" domains="" root="" role=""
  if ! __arg_choices_headers_use_applied; then __arg_choices_acl_domains; return; fi
  root="$(domain_config_root)" || return 1
  domains="$(domain_config_list applied)" || return 1
  [ -n "$domains" ] || return 0
  while IFS= read -r domain; do
    role="$(domain_config_get "$root/$domain/runtime/applied" domain.csv role)" || return 1
    case "$role" in backend | alias | dedicated) printf '%s\n' "$domain" ;; esac
  done <<<"$domains"
}

function __arg_choices_backend_header_domains() {
  local records="" line="" seen=$'\n' domain=""
  records="$(__arg_choices_backend_header_records)" || return 1
  [ -n "$records" ] || return 0
  while IFS= read -r line; do
    csv_parse_line "$line" || return 1
    domain="${CSV_FIELDS[0]}"
    case "$seen" in *$'\n'"$domain"$'\n'*) continue ;; esac
    seen="${seen}${domain}"$'\n'
    printf '%s\n' "$domain"
  done <<<"$records"
}

function __arg_choices_header_names() {
  local scope="$1" owner="$2" type="$3" records="" line="" name="" identity="" seen=$'\n' offset=0
  if [ "$scope" = backend ]; then
    records="$(__arg_choices_backend_header_records)" || return 1
    offset=1
  else
    records="$(__arg_choices_global_header_records)" || return 1
  fi
  [ -n "$records" ] || return 0
  while IFS= read -r line; do
    csv_parse_line "$line" || return 1
    [ -z "$owner" ] || [ "${CSV_FIELDS[0]}" = "$owner" ] || continue
    [ -z "$type" ] || [ "${CSV_FIELDS[offset]}" = "$type" ] || continue
    name="${CSV_FIELDS[offset + 1]}"
    identity="$(_header_name_identity "$name")" || return 1
    case "$seen" in *$'\n'"$identity"$'\n'*) continue ;; esac
    seen="${seen}${identity}"$'\n'
    printf '%s\n' "$name"
  done <<<"$records"
}

function __arg_choices_custom_header_names() {
  __arg_choices_header_names global '' "${1:-}"
}

function __arg_choices_backend_header_names() {
  local domain="${1:-}"
  [ -z "$domain" ] || domain="$(normalize_domain "$domain")" || return 1
  __arg_choices_header_names backend "$domain" "${2:-}"
}

# A conflict has no safe default, but must remain selectable for an explicit
# repair. Preserve exact values when all spellings agree; otherwise ask for one.
function _prompt_args_header_value() {
  local owner="$1" type="$2" name="$3" fallback="${4:-}" records="" line="" wanted="" value="" found=false offset=0
  wanted="$(_header_name_identity "$name")" || return 1
  if [ -n "$owner" ]; then
    owner="$(normalize_domain "$owner")" || return 1
    records="$(__arg_choices_backend_header_records)" || return 1
    offset=1
  else
    records="$(__arg_choices_global_header_records)" || return 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    csv_parse_line "$line" || return 1
    [ -z "$owner" ] || [ "${CSV_FIELDS[0]}" = "$owner" ] || continue
    [ "${CSV_FIELDS[offset]}" = "$type" ] || continue
    [ "$(_header_name_identity "${CSV_FIELDS[offset + 1]}")" = "$wanted" ] || continue
    if [ "$found" = true ] && [ "$value" != "${CSV_FIELDS[offset + 2]}" ]; then
      printf '[Info] Conflicting values exist for %s header %s%s; enter a replacement value.\n' "$type" "$name" "${owner:+ for $owner}" >&2
      return 0
    fi
    found=true
    value="${CSV_FIELDS[offset + 2]}"
  done <<<"$records"
  if [ "$found" = false ] && [ -n "$owner" ] && [ "$fallback" = global ]; then
    _prompt_args_header_value '' "$type" "$name"
    return
  fi
  printf '%s' "$value"
}
