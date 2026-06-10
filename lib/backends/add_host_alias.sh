# shellcheck shell=bash
function add_host_alias() {
  local alias="${1:-}" domain="${2:-}"
  if [ -z "$alias" ] || [ -z "$domain" ]; then
    echo "[Usage] add-host-alias <alias> <domain>"
    exit 1
  fi

  ensure_valid_or_prompt alias "$alias" "alias" "" is_valid_domain
  ensure_valid_or_prompt domain "$domain" "domain" "" is_valid_domain

  alias="$(normalize_domain "$alias")"
  domain="$(normalize_domain "$domain")"

  local target_domain
  target_domain="$(primary_domain_for "$domain")"

  if ! backend_exists "$target_domain"; then
    echo "[Error] Backend domain '$domain' not found." >&2
    exit 1
  fi
  if ! backend_has_httpish_port "$target_domain"; then
    echo "[Error] Alias target '$target_domain' has no HTTP/HTTPS port mapping. Add an HTTP/HTTPS port before creating aliases." >&2
    exit 1
  fi
  if backend_exists "$alias"; then
    echo "[Error] Cannot register alias '$alias' because it is already a backend domain." >&2
    exit 1
  fi
  if alias_exists "$alias"; then
    local existing_target
    existing_target="$(backend_for_alias "$alias")"
    if [ -n "$existing_target" ]; then
      echo "[Error] Alias '$alias' already points to backend '$existing_target'." >&2
    else
      echo "[Error] Alias '$alias' already exists." >&2
    fi
    exit 1
  fi

  local aliases_file
  aliases_file="$(backend_aliases_file)"
  local started_txn=false
  if ! _config_begin_transaction_if_needed started_txn "add_alias_${alias}"; then
    exit 1
  fi
  mkdir -p "$(dirname "$aliases_file")"
  state_csv_upsert_row_by_keys \
    "$aliases_file" "$STATE_BACKEND_ALIASES_HEADER" "$STATE_BACKEND_ALIASES_COLS" 2 \
    "alias" "$alias" \
    -- "alias" "$alias" "$target_domain"
  echo "[Info] Added host alias '${alias}' -> '${target_domain}'."
  log_msg "Added host alias ${alias} -> ${target_domain}"
  create_backup "" "AddAlias_${alias}"
  update_nginx_config
  _config_end_transaction_if_started "$started_txn"
}
