# shellcheck shell=bash

function _domain_cert_matching_port() {
  local domain="$1" port="$2" dir="" metadata=""
  for dir in "${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/certs/"*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    metadata="$dir/certificate.csv"
    [ -f "$metadata" ] || continue
    [ "$(_domain_runtime_get "$metadata" port_suffix)" = "$port" ] || continue
    printf '%s\n' "$dir"
  done
}

function _domain_cert_has_consumers() {
  local reference="$1" row="" number=0 normalized=""
  [ -f "$BACKEND_PORTS_FILE" ] || return 1
  csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 2
  while IFS= read -r row || [ -n "$row" ]; do
    number=$((number + 1)); [ "$number" -eq 1 ] && continue
    state_backend_ports_parse_line "$row" || return 2
    [ "$STATE_BP_RECORD_TYPE" = port ] && [ "$STATE_BP_PROTOCOL" = https ] || continue
    canonicalize_cert_ref_rel normalized "$STATE_BP_CERT_REF" || return 2
    [ "$normalized" != "$reference" ] || return 0
  done <"$BACKEND_PORTS_FILE"
  return 1
}

function domain_config_remove_certificate() {
  local domain="$1" port="$2" dir="" selected="" reference="" status=0 started=false
  local cert_root="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/certs"
  selected="$(_domain_cert_matching_port "$domain" "$port")" || return 1
  [ -n "$selected" ] || { echo "[Error] Certificate not found for ${domain}:${port}." >&2; return 1; }
  while IFS= read -r dir; do
    reference="$domain/${dir##*/}"
    status=0
    _domain_cert_has_consumers "$reference" || status=$?
    if [ "$status" -eq 0 ]; then
      echo "[Error] Cannot remove certificate $reference; HTTPS mappings still reference it." >&2
      return 1
    fi
    [ "$status" -eq 1 ] || return 1
  done <<<"$selected"
  _config_begin_transaction_if_needed started "remove_cert_${domain}_${port}" "$cert_root" || return 1
  while IFS= read -r dir; do
    runtime_state_path_guard_if_declared "$dir" "certificate removal" || return 1
    _domain_cert_record_removal "$domain" "${dir##*/}" || return 1
    safe_rm_rf "$dir" "$cert_root" || return 1
  done <<<"$selected"
  update_nginx_config || return 1
  create_backup "" "RemoveCert_${domain}_${port}" || return 1
  _config_end_transaction_if_started "$started" || return 1
  if [ -z "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ]; then
    while IFS= read -r dir; do _domain_cert_remove_external_material "$domain" "${dir##*/}" || return 1; done <<<"$selected"
  fi
}

function _domain_cert_record_removal() {
  local domain="$1" id="$2" directory="" source="" key="" owner="" matched_owner="" matched_id=""
  local provider="" port="" identity="" verified=no explicit_source=false status=0
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 1
  domain_config_certificate_dir directory "$domain" "$id" || return 1
  [ ! -L "$directory/certificate.csv" ] || return 1
  source="$(_domain_runtime_get "$directory/certificate.csv" source_ref)" || return 1
  if [ -n "$source" ]; then
    explicit_source=true
  else
    provider="${id%-*}"; port="${id##*-}"
    case "$provider" in
    selfsigned | custom | letsencrypt)
      if is_valid_port "$port"; then source="$CERTS_DIR/$provider/live/${domain}_${port}"; fi
      ;;
    esac
  fi
  if [ -n "$source" ]; then
    _domain_cert_legacy_ref_key key owner "$source" || status=$?
    [ "$status" -ne 2 ] || return 1
    if [ "$status" -eq 0 ]; then
      [ "$owner" = "$domain" ] || {
        printf '[Error] Refusing legacy certificate cleanup across owners.\n' >&2; return 1;
      }
      status=0
      _domain_cert_saved_reference matched_owner matched_id "$key" "$owner" || status=$?
      if [ "$status" -eq 0 ]; then
        [ "$matched_owner" = "$domain" ] && [ "$matched_id" = "$id" ] || return 1
      elif [ "$status" -ne 1 ] || [ "$explicit_source" = true ]; then
        return 1
      fi
      source="${CERTS_DIR%/}/$key"
      identity=absent
      if [ -e "$source" ] || [ -L "$source" ]; then identity="$(_backup_directory_identity "$source")" || return 1; fi
      verified=yes
    fi
  fi
  _domain_runtime_record certificate_remove "$domain" certificate_id "$id" legacy_source_ref "$source" \
    legacy_source_verified "$verified" legacy_source_key "$key" legacy_source_owner "$owner" \
    legacy_source_id "$id" legacy_source_identity "$identity" || return 1
  _domain_runtime_finish_operation
}

# Issuer accounts are shared, but a removed certificate's retry receipts and
# unreferenced issuer lineage are deleted only after its runtime commit.
function _domain_cert_remove_external_material() {
  local domain="$1" id="$2" legacy="${3:-}" record="${4:-}" receipt="" dir="" issuer="" path=""
  is_valid_domain "$domain" && _domain_cert_id_valid "$id" || return 1
  _domain_cert_remove_legacy_material "$domain" "$id" "$legacy" "$record" || return 1
  receipt="${STATE_DIR}/shared/certificate_receipts/$domain/$id"
  runtime_state_path_guard_if_declared "$receipt" "removed certificate receipt" || return 1
  if [ -d "$receipt" ]; then safe_rm_rf "$receipt" "${STATE_DIR}/shared/certificate_receipts" || return 1; fi
  for dir in "${DOMAINS_DIR:-${STATE_DIR}/domains}/$domain/certs/"*; do
    [ -f "$dir/certificate.csv" ] || continue
    [ "$(_domain_runtime_get "$dir/certificate.csv" provider)" != letsencrypt ] || return 0
  done
  issuer="$(_domain_cert_acme_root)" || return 1
  for path in "$issuer/live/$domain" "$issuer/archive/$domain"; do
    runtime_state_path_guard_if_declared "$path" "removed certificate issuer lineage" || return 1
    if [ -d "$path" ]; then safe_rm_rf "$path" "${path%/*}" || return 1; fi
  done
  path="$issuer/renewal/$domain.conf"
  runtime_state_path_guard_if_declared "$path" "removed certificate renewal configuration" || return 1
  if [ -f "$path" ]; then safe_rm_f "$path" "${path%/*}" || return 1; fi
}

function _domain_cert_remove_legacy_material() {
  local domain="$1" id="$2" source="${3:-}" record="${4:-}" provider="" port="" source_owner="" source_id=""
  local saved_key="" checked_key="" identity="" actual_identity=""
  if [ -n "$record" ]; then
    [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 1
    case "$record" in "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}/operations/"*.csv) ;; *) return 1 ;; esac
    runtime_state_path_guard_if_declared "$record" "certificate cleanup intent" || return 1
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
  fi
  if [ -n "$record" ] && [ "$(_domain_runtime_get "$record" legacy_source_verified no)" = yes ]; then
    [ "$(_domain_runtime_get "$record" ready no)" = yes ] &&
      [ "$(_domain_runtime_get "$record" mode)" = certificate_remove ] &&
      [ "$(_domain_runtime_get "$record" domain)" = "$domain" ] &&
      [ "$(_domain_runtime_get "$record" certificate_id)" = "$id" ] &&
      [ "$(_domain_runtime_get "$record" legacy_source_owner)" = "$domain" ] &&
      [ "$(_domain_runtime_get "$record" legacy_source_id)" = "$id" ] || return 1
    saved_key="$(_domain_runtime_get "$record" legacy_source_key)" || return 1
    _domain_cert_legacy_ref_key checked_key source_owner "$source" || return 1
    [ "$checked_key" = "$saved_key" ] && [ "$source_owner" = "$domain" ] || return 1
    source="${CERTS_DIR%/}/$checked_key"
    [ -e "$source" ] || [ -L "$source" ] || return 0
    identity="$(_domain_runtime_get "$record" legacy_source_identity)" || return 1
    actual_identity="$(_backup_directory_identity "$source")" || return 1
    if [ "$identity" != "$actual_identity" ]; then
      printf '[Error] Legacy certificate directory changed after removal was prepared: %s\n' "$source" >&2
      return 1
    fi
    safe_rm_rf "$source" "${source%/*}"
    return $?
  fi
  if [ -z "$source" ]; then
    provider="${id%-*}"; port="${id##*-}"
    case "$provider" in selfsigned | custom | letsencrypt) ;; *) return 0 ;; esac
    is_valid_port "$port" || return 0
    source="${CERTS_DIR}/${provider}/live/${domain}_${port}"
  fi
  case "$source" in
  "$CERTS_DIR"/selfsigned/live/* | "$CERTS_DIR"/custom/live/* | "$CERTS_DIR"/letsencrypt/live/*) ;;
  *) return 0 ;; # Restore staging roots are not live legacy material.
  esac
  [ -e "$source" ] || [ -L "$source" ] || return 0
  domain_config_cert_ref_split source_owner source_id "$source" || return 1
  if [ "$source_owner" != "$domain" ] || [ "$source_id" != "$id" ]; then
    printf '[Error] Refusing legacy certificate cleanup across owner or certificate identity.\n' >&2
    return 1
  fi
  runtime_state_path_guard_if_declared "$source" "removed legacy certificate copy" || return 1
  safe_rm_rf "$source" "${source%/*}"
}

function domain_config_replace_certificate() {
  local domain="$1" port="$2" provider="$3" source_cert="${4:-}" source_key="${5:-}"
  local selected="" dir="" count=0 chosen="" started=false
  local caller_skip_update="${SKIP_UPDATE_NGINX_CONFIG:-}"
  local DOMAIN_CONFIG_CERTIFICATE_ID="" SKIP_UPDATE_NGINX_CONFIG=true
  local CERT_AUTOCONFIG_DISABLED=1
  selected="$(_domain_cert_matching_port "$domain" "$port")" || return 1
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    count=$((count + 1)); chosen="${dir##*/}"
  done <<<"$selected"
  if [ "$count" -gt 1 ]; then
    echo "[Error] Multiple certificate IDs use ${domain}:${port}; select the intended ID in certificates.csv and apply the domain." >&2
    return 1
  fi
  DOMAIN_CONFIG_CERTIFICATE_ID="$chosen"
  _config_begin_transaction_if_needed started "replace_cert_${domain}_${port}" "${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/certs" || return 1
  add_cert "$domain" "$port" "$provider" "$source_cert" "$source_key" || return 1
  # Issuance is staged first; the outer command must still activate the new
  # certificate projection after validating its complete candidate.
  SKIP_UPDATE_NGINX_CONFIG="$caller_skip_update"
  update_nginx_config || return 1
  _config_end_transaction_if_started "$started"
}

# Certificate provisioning precedes candidate HTTPS rendering. Refresh only
# the applied default challenge handler while existing domain blocks and their
# mounted certificate snapshot remain available for Nginx validation.
function _domain_config_prepare_acme_challenge() {
  transaction_is_active || return 1
  _nginx_prepare_runtime_rollback "$NGINX_IMAGE" || return 1
  domain_config_runtime_capture_proxy || return 1
  _with_validated_render_settings fix_default_config || return 1
  docker exec "$NGINX_CONTAINER_NAME" nginx -t -c "$NGINX_CONTAINER_MAIN_CONF" || return 1
  _nginx_mark_runtime_rollback_needed || return 1
  reload_nginx_if_running
}
