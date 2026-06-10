# shellcheck shell=bash

function list_nginx_directive_catalog() {
  local scope="" directive="" dtype="" owner="" context_label=""

  printf "%-7s | %-28s | %-16s | %s\n" "Context" "Directive" "Type" "Owner"
  echo "-------------------------------------------------------------------------------------------------"

  for scope in "$NGINX_DIRECTIVE_SCOPE_GLOBAL" "$NGINX_DIRECTIVE_SCOPE_STREAM_GLOBAL"; do
    if nginx_directive_scope_is_stream "$scope"; then
      context_label="stream"
    else
      context_label="http"
    fi
    for directive in $(nginx_directive_catalog_keys_for_scope "$scope"); do
      dtype="$(nginx_directive_catalog_type_for_scope "$scope" "$directive" 2>/dev/null || echo unknown)"
      owner="$(nginx_directive_resolve_owner_guidance "$directive")"
      [ -z "$owner" ] && owner="-"
      printf "%-7s | %-28s | %-16s | %s\n" "$context_label" "$directive" "$dtype" "$owner"
    done
  done
}
