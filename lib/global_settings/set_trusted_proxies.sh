# shellcheck shell=bash

# Control trusted proxy ranges for the real_ip module
function set_trusted_proxies() {
  local ranges="${*}"
  local new_ranges=""
  if [ "$ranges" = "none" ]; then
    new_ranges=""
  else
    [ -z "$ranges" ] && {
      echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-trusted-proxies <cidr_list|none>" >&2
      return 1
    }
    # Support comma or space separated lists
    ranges="${ranges//,/ }"
    # Validate each token
    local out="" tok ok=true
    for tok in $ranges; do
      if is_valid_ip_or_cidr "$tok"; then
        out+=" ${tok}"
      else
        echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid proxy range token: $tok" >&2
        ok=false
      fi
    done
    [ "$ok" = true ] || return 1
    new_ranges="${out# }"
  fi
  local started_txn=false
  _config_begin_return_transaction_if_needed started_txn "set_trusted_proxies" || return 1
  TRUSTED_PROXY_RANGES="$new_ranges"
  save_config || { transaction_return_failure; return 1; }
  if [ -n "$TRUSTED_PROXY_RANGES" ]; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} TRUSTED_PROXY_RANGES set to $TRUSTED_PROXY_RANGES and saved in $GLOBAL_SETTINGS_FILE."
  else
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} TRUSTED_PROXY_RANGES cleared in $GLOBAL_SETTINGS_FILE."
  fi
  update_nginx_config || { transaction_return_failure; return 1; }
  _config_end_transaction_if_started "$started_txn" || { transaction_return_failure; return 1; }
}
