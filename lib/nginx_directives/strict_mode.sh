# shellcheck shell=bash

function nginx_directives_require_generic_write_allowed() {
  local directive="${1:-}"
  if nginx_directive_strict_is_on && nginx_directive_is_owned "$directive"; then
    local owner
    owner="$(nginx_directive_resolve_owner_guidance "$directive")"
    echo "[Error] Directive '${directive}' is managed by '${owner}'. Disable strict mode or use the owner command." >&2
    return 1
  fi
  return 0
}

function nginx_directives_require_generic_remove_allowed() {
  local directive="${1:-}"
  if nginx_directive_strict_is_on && nginx_directive_is_owned "$directive"; then
    local owner
    owner="$(nginx_directive_resolve_owner_guidance "$directive")"
    echo "[Error] Directive '${directive}' is managed by '${owner}'. Disable strict mode or use the owner command." >&2
    return 1
  fi
  return 0
}

function nginx_directives_validate_strict_owned_rows() {
  local line="" line_no=0 mode directive

  if ! nginx_directive_strict_is_on; then
    return 0
  fi

  [ -f "$NGINX_DIRECTIVES_FILE" ] || return 0
  nginx_directives_ensure_state_file || return 1

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))
    [ "$line_no" -eq 1 ] && continue

    if ! csv_parse_line "$line"; then
      echo "[Error] Invalid nginx directives row at line ${line_no}: ${CSV_PARSE_ERROR}" >&2
      return 1
    fi
    if [ "$CSV_FIELD_COUNT" -ne "$STATE_NGINX_DIRECTIVES_COLS" ]; then
      echo "[Error] Invalid nginx directives row width at line ${line_no}: expected ${STATE_NGINX_DIRECTIVES_COLS}, got ${CSV_FIELD_COUNT}." >&2
      return 1
    fi

    mode="${CSV_FIELDS[4]}"
    directive="${CSV_FIELDS[5]}"
    if nginx_directive_is_owned "$directive" && [ "$mode" != "$NGINX_DIRECTIVE_MODE_MANAGED" ]; then
      echo "[Error] Strict mode is on and directive '${directive}' has unmanaged state at line ${line_no}. Disable strict mode first and remove the unmanaged row, or use the owner command." >&2
      return 1
    fi
  done <"$NGINX_DIRECTIVES_FILE"

  return 0
}

function nginx_directives_set_managed_owned() {
  local scope="${1:-}" domain="${2:-}" listen_port="${3:-}" path_prefix="${4:-}" directive="${5:-}" value="${6:-}"

  if ! nginx_directive_is_owned "$directive"; then
    echo "[Error] Directive '${directive}' is not registered as owned; managed writes are not allowed." >&2
    return 1
  fi

  if ! nginx_directive_validate_name_token "$directive"; then
    echo "[Error] Invalid directive token: ${directive}" >&2
    return 1
  fi
  if ! nginx_directive_validate_raw_value "$value"; then
    echo "[Error] Invalid directive value for '${directive}'." >&2
    return 1
  fi
  if nginx_directive_catalog_contains_for_scope "$scope" "$directive"; then
    nginx_directive_catalog_validate_for_scope "$scope" "$directive" "$value" || return 1
  fi

  nginx_directives_state_upsert "$scope" "$domain" "$listen_port" "$path_prefix" "$NGINX_DIRECTIVE_MODE_MANAGED" "$directive" "$value"
}
