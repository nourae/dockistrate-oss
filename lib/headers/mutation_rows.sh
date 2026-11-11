# shellcheck shell=bash

# Edit only the requested logical header. Read structurally before semantic
# validation so an explicit setter/remover can repair historical conflicts.
function _header_mutation_record() {
  shift 2
  local owner="" type="" name="" identity=""
  if [ "$_hm_scope" = backend ]; then owner="$1"; shift; fi
  type="$1"; name="$2"
  identity="$(_header_name_identity "$name")" || return 1
  if { [ "$_hm_scope" != backend ] || [ "$owner" = "$_hm_owner" ]; } &&
    { [ "$_hm_action" = clear ] || { [ "$type" = "$_hm_type" ] && [ "$identity" = "$_hm_identity" ]; }; }; then
    return 0
  fi
  if [ "$_hm_scope" = backend ]; then csv_join_row "$owner" "$@"; else csv_join_row "$@"; fi
}

function _header_mutate_file() {
  local file="$1" _hm_scope="$2" _hm_action="$3" _hm_owner="$4" _hm_type="${5:-}" name="${6:-}" value="${7:-}"
  local _hm_identity="" header="header_type,header_name,header_value" temporary=""
  [ "$_hm_scope" != backend ] || header="$STATE_BACKEND_HEADERS_HEADER"
  [ "$_hm_scope" != global ] || header="$STATE_CUSTOM_HEADERS_HEADER"
  _hm_identity="$(_header_name_identity "$name")" || return 1
  make_temp_for_file temporary "$file" || return 1
  if ! {
    printf '%s\n' "$header" &&
      csv_read_records "$file" "$header" _header_mutation_record table &&
      if [ "$_hm_action" = set ]; then
        if [ "$_hm_scope" = backend ]; then
          csv_join_row "$_hm_owner" "$_hm_type" "$name" "$value"
        else
          csv_join_row "$_hm_type" "$name" "$value"
        fi
      fi
  } >"$temporary"; then rm -f "$temporary"; return 1; fi
  finalize_temp_file_with_mode "$file" "$temporary" 600
}
