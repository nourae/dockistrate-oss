# shellcheck shell=bash

function domain_config_certificate_layout() {
  [ "${DOMAIN_CONFIG_ACTIVE:-false}" = true ] ||
    { declare -F domain_config_active >/dev/null 2>&1 && domain_config_active; }
}

function _domain_cert_id_valid() {
  case "${1:-}" in '' | . | .. | *[!a-zA-Z0-9_.-]*) return 1 ;; esac
}

function _domain_cert_acme_root() {
  if domain_config_certificate_layout; then
    printf '%s/shared/acme\n' "${STATE_DIR%/}"
  else
    printf '%s/letsencrypt\n' "${CERTS_DIR%/}"
  fi
}

function _domain_cert_legacy_ref_key() {
  local key_out="$1" owner_out="$2" reference="${3:-}" legacy_root="${CERTS_DIR%/}" physical_root=""
  local _dcl_key="" _dcl_owner="" remainder="" component="" leaf=""
  require_valid_var_name "$key_out" && require_valid_var_name "$owner_out" || return 2
  while [ "${reference%/}" != "$reference" ]; do reference="${reference%/}"; done
  if [[ "$reference" = /* ]]; then
    case "$reference" in
    "$legacy_root"/*) reference="${reference#"$legacy_root"/}" ;;
    *)
      physical_root="$(_realpath_portable "$legacy_root" 2>/dev/null)" || return 1
      case "$reference" in "$physical_root"/*) reference="${reference#"$physical_root"/}" ;; *) return 1 ;; esac
      ;;
    esac
  fi
  # Removing '.' components preserves the old contained spellings without
  # resolving '..', links, or paths supplied from outside the legacy root.
  remainder="$reference"
  while [ -n "$remainder" ]; do
    component="${remainder%%/*}"
    if [ "$remainder" = "$component" ]; then remainder=""; else remainder="${remainder#*/}"; fi
    case "$component" in '' | .) continue ;; ..) return 2 ;; esac
    if [ -n "$_dcl_key" ]; then _dcl_key+="/$component"; else _dcl_key="$component"; fi
  done
  _dcl_key="${_dcl_key#certs/}"
  case "$_dcl_key" in selfsigned/live/* | custom/live/* | letsencrypt/live/*) ;; *) return 1 ;; esac
  leaf="${_dcl_key#*/live/}"
  case "$leaf" in '' | */*) return 2 ;; esac
  _dcl_owner="$leaf"
  if [[ "$leaf" =~ ^(.+)_([0-9]+)$ ]]; then _dcl_owner="${BASH_REMATCH[1]}"; fi
  _dcl_owner="$(normalize_domain "$_dcl_owner")"
  is_valid_domain "$_dcl_owner" || return 2
  _runtime_path_reject_symlink_prefix_components "$legacy_root/$_dcl_key" "legacy certificate reference" || return 2
  runtime_state_path_guard_if_declared "$legacy_root/$_dcl_key" "legacy certificate reference" || return 2
  printf -v "$key_out" '%s' "$_dcl_key"
  printf -v "$owner_out" '%s' "$_dcl_owner"
}

function _domain_cert_saved_reference() {
  local owner_out="$1" id_out="$2" key="$3" expected_owner="$4"
  local directory="" metadata="" source="" source_key="" source_owner="" found_id="" candidate_id=""
  local certificates="${DOMAINS_DIR:-${STATE_DIR}/domains}/$expected_owner/certs"
  runtime_state_path_guard_if_declared "$certificates" "certificate reference map" || return 2
  for directory in "$certificates/"*; do
    [ -d "$directory" ] || continue
    candidate_id="${directory##*/}"
    _domain_cert_id_valid "$candidate_id" || return 2
    runtime_state_path_guard_if_declared "$directory" "mapped certificate directory" || return 2
    metadata="$directory/certificate.csv"
    [ ! -L "$metadata" ] || return 2
    [ -f "$metadata" ] || continue
    source="$(_domain_runtime_get "$metadata" source_ref)" || return 2
    [ -n "$source" ] || continue
    _domain_cert_legacy_ref_key source_key source_owner "$source" 2>/dev/null || continue
    [ "$source_key" = "$key" ] && [ "$source_owner" = "$expected_owner" ] || continue
    if [ -n "$found_id" ]; then
      printf '[Error] Legacy certificate reference %s maps to multiple managed certificate IDs for %s. Use an explicit owner/id reference.\n' "$key" "$expected_owner" >&2
      return 2
    fi
    found_id="$candidate_id"
  done
  [ -n "$found_id" ] || return 1
  printf -v "$owner_out" '%s' "$expected_owner"
  printf -v "$id_out" '%s' "$found_id"
}

function domain_config_cert_ref_split() {
  local owner_out="$1" id_out="$2" ref="${3:-}" fallback="${4:-}"
  local _dc_owner="" _dc_id="" provider="" leaf="" port=443 root="${DOMAINS_DIR:-${STATE_DIR}/domains}"
  local legacy_key="" legacy_owner="" reference_status=0
  require_valid_var_name "$owner_out" && require_valid_var_name "$id_out" || return 1
  case "$ref" in
  "$root"/*/certs/*)
    leaf="${ref#"$root"/}"; _dc_owner="${leaf%%/*}"; _dc_id="${leaf#*/certs/}"
    ;;
  *)
    case "$ref" in */live/* | certs/* | ./*)
      _domain_cert_legacy_ref_key legacy_key legacy_owner "$ref" || reference_status=$?
      [ "$reference_status" -ne 2 ] || return 1
      if [ "$reference_status" -eq 0 ]; then
        reference_status=0
        _domain_cert_saved_reference _dc_owner _dc_id "$legacy_key" "$legacy_owner" || reference_status=$?
        if [ "$reference_status" -eq 0 ]; then
          printf -v "$owner_out" '%s' "$_dc_owner"
          printf -v "$id_out" '%s' "$_dc_id"
          return 0
        fi
        [ "$reference_status" -eq 1 ] || return 1
        ref="$legacy_key"
      fi
      ;;
    esac
    ref="${ref#"${CERTS_DIR%/}/"}"; ref="${ref#certs/}"
    case "$ref" in
    selfsigned/live/* | custom/live/* | letsencrypt/live/*)
      provider="${ref%%/*}"; leaf="${ref#*/live/}"
      if [[ "$leaf" =~ ^(.+)_([0-9]+)$ ]]; then
        _dc_owner="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
      else
        _dc_owner="$leaf"
      fi
      _dc_id="${provider}-${port}"
      ;;
    */*) _dc_owner="${ref%%/*}"; _dc_id="${ref#*/}" ;;
    *)
      [ -n "$fallback" ] || return 1
      _dc_owner="$fallback"
      _dc_id="imported-$(printf '%s' "$ref" | _sha256_digest_stdin | cut -c1-16)" || return 1
      ;;
    esac
    ;;
  esac
  _dc_owner="$(normalize_domain "$_dc_owner")"
  is_valid_domain "$_dc_owner" && _domain_cert_id_valid "$_dc_id" || return 1
  printf -v "$owner_out" '%s' "$_dc_owner"
  printf -v "$id_out" '%s' "$_dc_id"
}

function domain_config_certificate_dir() {
  local output="$1" owner="${2:-}" cert_id="${3:-}" _dc_dir_value=""
  require_valid_var_name "$output" || return 1
  is_valid_domain "$owner" && [ "$owner" = "$(normalize_domain "$owner")" ] && _domain_cert_id_valid "$cert_id" || return 1
  _dc_dir_value="${DOMAINS_DIR:-${STATE_DIR}/domains}/${owner}/certs/${cert_id}"
  runtime_state_path_guard_if_declared "$_dc_dir_value" "domain certificate directory" || return 1
  printf -v "$output" '%s' "$_dc_dir_value"
}

function _domain_cert_resolve_ref() {
  local output="$1" ref="${2:-}" owner="" cert_id="" _dc_resolved_value=""
  if ! domain_config_cert_ref_split owner cert_id "$ref"; then
    printf "[Error] Certificate directory '%s' must reside within '%s/<domain>/certs/<certificate_id>'; use a managed owner/id reference.\n" \
      "$ref" "${DOMAINS_DIR:-${STATE_DIR}/domains}" >&2
    return 1
  fi
  domain_config_certificate_dir _dc_resolved_value "$owner" "$cert_id" || return 1
  printf -v "$output" '%s' "$_dc_resolved_value"
}

function _domain_cert_destination() {
  local output="$1" owner="$2" provider="$3" port="$4" _dc_dest_value=""
  if domain_config_certificate_layout; then
    domain_config_certificate_dir _dc_dest_value "$owner" "${DOMAIN_CONFIG_CERTIFICATE_ID:-${provider}-${port}}" || return 1
  else
    _dc_dest_value="${CERTS_DIR}/${provider}/live/${owner}_${port}"
  fi
  printf -v "$output" '%s' "$_dc_dest_value"
}

function _domain_cert_write_metadata() {
  local dir="$1" provider="$2" port="$3" source="${4:-}"
  _domain_runtime_put "$dir/certificate.csv" provider "$provider" || return 1
  _domain_runtime_put "$dir/certificate.csv" port_suffix "$port" || return 1
  if [ "$#" -ge 4 ]; then _domain_runtime_put "$dir/certificate.csv" source_ref "$source" || return 1; fi
  _tighten_file_permissions "$dir/certificate.csv" 600
}

function _domain_cert_valid_pair() {
  local dir="$1" mode="${2:-apply}" cert_key="" private_key=""
  [ -f "$dir/fullchain.pem" ] && [ -f "$dir/privkey.pem" ] || return 1
  [ ! -L "$dir/fullchain.pem" ] && [ ! -L "$dir/privkey.pem" ] || return 1
  case "$mode" in
  apply) openssl x509 -in "$dir/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || return 1 ;;
  restore) openssl x509 -in "$dir/fullchain.pem" -noout >/dev/null 2>&1 || return 1 ;;
  *) return 1 ;;
  esac
  cert_key="$(openssl x509 -in "$dir/fullchain.pem" -pubkey -noout 2>/dev/null | _sha256_digest_stdin)" || return 1
  private_key="$(openssl pkey -in "$dir/privkey.pem" -pubout 2>/dev/null | _sha256_digest_stdin)" || return 1
  [ -n "$cert_key" ] && [ "$cert_key" = "$private_key" ]
}

function domain_config_export_certificates() {
  local domain="$1" config_dir="$2" file="" options_file="" dir="" provider="" port="" id="" owner=""
  local source_cert="" source_key="" accepted=""
  file="$config_dir/certificates.csv"; options_file="$config_dir/certificate_options.csv"
  _domain_csv_write_header "$file" || return 1
  if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then _domain_csv_write_header "$options_file" || return 1; fi
  for dir in "${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/certs/"*; do
    [ -d "$dir" ] && [ -f "$dir/fullchain.pem" ] || continue
    [ "$(_domain_runtime_get "$dir/certificate.csv" declared yes)" != no ] || continue
    id="${dir##*/}"
    _domain_cert_id_valid "$id" || return 1
    provider=custom; port=443; source_cert=""; source_key=""
    if [ -f "$dir/certificate.csv" ]; then
      provider="$(_domain_runtime_get "$dir/certificate.csv" provider custom)" || return 1
      port="$(_domain_runtime_get "$dir/certificate.csv" port_suffix 443)" || return 1
      source_cert="$(_domain_runtime_get "$dir/certificate.csv" source_fullchain __unset__)" || return 1
      source_key="$(_domain_runtime_get "$dir/certificate.csv" source_privkey __unset__)" || return 1
    fi
    accepted="${DOMAINS_DIR:-${STATE_DIR}/domains}/${domain}/runtime/applied"
    if [ "$source_cert" = __unset__ ]; then
      source_cert=""
      if [ "$provider" = custom ]; then source_cert="$(domain_config_certificate_option "$accepted" "$id" source_fullchain)" || return 1; fi
    fi
    if [ "$source_key" = __unset__ ]; then
      source_key=""
      if [ "$provider" = custom ]; then source_key="$(domain_config_certificate_option "$accepted" "$id" source_privkey)" || return 1; fi
    fi
    if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
      state_csv_upsert_row_by_keys "$file" 'certificate_id,provider,port_suffix' 3 1 "$id" -- "$id" "$provider" "$port" || return 1
      [ -z "$source_cert" ] || _domain_csv_set "$options_file" "$id" source_fullchain "$source_cert" || return 1
      [ -z "$source_key" ] || _domain_csv_set "$options_file" "$id" source_privkey "$source_key" || return 1
    else
      state_csv_upsert_row_by_keys "$file" 'certificate_id,provider,port_suffix,source_fullchain,source_privkey' 5 1 "$id" -- "$id" "$provider" "$port" "$source_cert" "$source_key" || return 1
    fi
  done
  # Legacy material is only a migration source, never a second schema-2 authority.
  if ! domain_config_certificate_layout; then
    for provider in selfsigned letsencrypt custom; do
      for dir in "${CERTS_DIR}/${provider}/live/"*; do
        [ -d "$dir" ] && [ -f "$dir/fullchain.pem" ] || continue
        domain_config_cert_ref_split owner id "$dir" "$domain" || continue
        [ "$owner" = "$domain" ] || continue
        port="${id##*-}"
        if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
          state_csv_upsert_row_by_keys "$file" 'certificate_id,provider,port_suffix' 3 1 "$id" -- "$id" "$provider" "$port" || return 1
        else
          state_csv_upsert_row_by_keys "$file" 'certificate_id,provider,port_suffix,source_fullchain,source_privkey' 5 1 "$id" -- "$id" "$provider" "$port" '' '' || return 1
        fi
      done
    done
  fi
}

function _domain_cert_fingerprint() {
  csv_join_row "$@" | _sha256_digest_stdin
}

function _domain_cert_matches_specification() {
  local dir="$1" expected="$2" actual="" provider="" port="" cert="" key=""
  _domain_cert_valid_pair "$dir" "${3:-apply}" || return 1
  [ -f "$dir/certificate.csv" ] || return 1
  actual="$(_domain_runtime_get "$dir/certificate.csv" specification)" || return 1
  if [ -z "$actual" ]; then
    provider="$(_domain_runtime_get "$dir/certificate.csv" provider custom)" || return 1
    port="$(_domain_runtime_get "$dir/certificate.csv" port_suffix 443)" || return 1
    cert="$(_domain_runtime_get "$dir/certificate.csv" source_fullchain)" || return 1
    key="$(_domain_runtime_get "$dir/certificate.csv" source_privkey)" || return 1
    actual="$(_domain_cert_fingerprint "${dir##*/}" "$provider" "$port" "$cert" "$key")" || return 1
  fi
  [ "$actual" = "$expected" ]
}

function domain_config_provision_certificates() {
  local candidate="$1" domain_dir="" domain="" file="" row="" rows=""
  local cert_id="" provider="" port="" source_cert="" source_key="" destination="" fingerprint="" receipt="" material=""
  local SKIP_UPDATE_NGINX_CONFIG=true CERT_AUTOCONFIG_DISABLED=1 INTERACTIVE=false DOMAIN_CONFIG_CERTIFICATE_ID=""
  transaction_is_active || return 1
  for domain_dir in "$candidate"/*; do
    [ -d "$domain_dir/config" ] || continue
    domain="${domain_dir##*/}"
    _domain_config_domain_selected "$domain" || continue
    for material in "${DOMAINS_DIR:-${STATE_DIR}/domains}/$domain/certs/"*; do
      [ -d "$material" ] && [ -f "$material/certificate.csv" ] || continue
      _domain_runtime_put "$material/certificate.csv" declared no || return 1
    done
    file="$domain_dir/config/certificates.csv"
    [ -f "$file" ] || continue
    rows="$(_domain_csv_rows "$file")" || return 1
    while IFS= read -r row || [ -n "$row" ]; do
      [ -n "$row" ] || continue
      csv_parse_line "$row" || return 1
      cert_id="${CSV_FIELDS[0]}" provider="${CSV_FIELDS[1]}" port="${CSV_FIELDS[2]}"
      if [ "${DOMAIN_CONFIG_INPUT_SCHEMA_VERSION:-5}" = 3 ]; then
        source_cert="$(domain_config_certificate_option "$domain_dir/config" "$cert_id" source_fullchain)" || return 1
        source_key="$(domain_config_certificate_option "$domain_dir/config" "$cert_id" source_privkey)" || return 1
      else
        source_cert="${CSV_FIELDS[3]}"; source_key="${CSV_FIELDS[4]}"
      fi
      domain_config_certificate_dir destination "$domain" "$cert_id" || return 1
      fingerprint="$(_domain_cert_fingerprint "$cert_id" "$provider" "$port" "$source_cert" "$source_key")" || return 1
      if _domain_cert_matches_specification "$destination" "$fingerprint"; then
        _domain_cert_write_metadata "$destination" "$provider" "$port" || return 1
        _domain_runtime_put "$destination/certificate.csv" declared yes || return 1
        _domain_runtime_put "$destination/certificate.csv" specification "$fingerprint" || return 1
        _domain_runtime_put "$destination/certificate.csv" source_fullchain "$source_cert" || return 1
        _domain_runtime_put "$destination/certificate.csv" source_privkey "$source_key" || return 1
        continue
      fi
      # Successful external issuance is outside content rollback. A failed
      # later apply can reuse its checked private result without contacting CA.
      receipt="${STATE_DIR}/shared/certificate_receipts/${domain}/${cert_id}/${fingerprint}"
      runtime_state_path_guard_if_declared "$receipt" "certificate issuance receipt" || return 1
      if [ "$provider" = letsencrypt ] && _domain_cert_valid_pair "$receipt"; then
        (umask 077; mkdir -p "$destination") || return 1
        copy_file_atomic "$receipt/fullchain.pem" "$destination/fullchain.pem" 640 || return 1
        copy_file_atomic "$receipt/privkey.pem" "$destination/privkey.pem" 600 || return 1
      else
        DOMAIN_CONFIG_CERTIFICATE_ID="$cert_id"
        case "$provider" in
        selfsigned | letsencrypt) add_cert "$domain" "$port" "$provider" || return 1 ;;
        custom) add_cert "$domain" "$port" upload "$source_cert" "$source_key" || return 1 ;;
        *) return 1 ;;
        esac
        _domain_cert_valid_pair "$destination" || return 1
        if [ "$provider" = letsencrypt ]; then
          (umask 077; mkdir -p "$receipt") || return 1
          copy_file_atomic "$destination/fullchain.pem" "$receipt/fullchain.pem" 640 || return 1
          copy_file_atomic "$destination/privkey.pem" "$receipt/privkey.pem" 600 || return 1
        fi
      fi
      _domain_cert_write_metadata "$destination" "$provider" "$port" || return 1
      _domain_runtime_put "$destination/certificate.csv" declared yes || return 1
      _domain_runtime_put "$destination/certificate.csv" specification "$fingerprint" || return 1
      _domain_runtime_put "$destination/certificate.csv" source_fullchain "$source_cert" || return 1
      _domain_runtime_put "$destination/certificate.csv" source_privkey "$source_key" || return 1
    done <<<"$rows"
  done
}

# Called under the migration transaction, after export but before its schema
# marker. Copies leave mounted legacy certificate projections untouched.
function domain_config_migrate_certificates() {
  local legacy_root="${1:-$CERTS_DIR}" provider="" dir="" owner="" cert_id="" destination="" port="" source=""
  local DOMAIN_CONFIG_ACTIVE=true
  for provider in selfsigned custom letsencrypt; do
    for dir in "$legacy_root/$provider/live/"*; do
      [ -d "$dir" ] && [ -f "$dir/fullchain.pem" ] && [ -f "$dir/privkey.pem" ] || continue
      domain_config_cert_ref_split owner cert_id "$dir" || return 1
      domain_config_certificate_dir destination "$owner" "$cert_id" || return 1
      (umask 077; mkdir -p "$destination") || return 1
      copy_file_atomic "$dir/fullchain.pem" "$destination/fullchain.pem" 640 || return 1
      copy_file_atomic "$dir/privkey.pem" "$destination/privkey.pem" 600 || return 1
      port="${cert_id##*-}"
      _domain_cert_write_metadata "$destination" "$provider" "$port" "$dir" || return 1
    done
  done
  for dir in "$legacy_root/mtls/"*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    owner="${dir##*/}"; is_valid_domain "$owner" || return 1
    destination="${DOMAINS_DIR:-${STATE_DIR}/domains}/${owner}/mtls"
    runtime_state_path_guard_if_declared "$destination" "migrated mTLS directory" || return 1
    (umask 077; mkdir -p "$destination") || return 1
    cp -R "$dir/." "$destination/" || return 1
  done
  if [ -d "$legacy_root/letsencrypt" ]; then
    destination="$(_domain_cert_acme_root)" || return 1
    runtime_state_path_guard_if_declared "$destination" "migrated ACME directory" || return 1
    (umask 077; mkdir -p "$destination") || return 1
    cp -R "$legacy_root/letsencrypt/." "$destination/" || return 1
  fi
}
