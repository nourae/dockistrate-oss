# shellcheck shell=bash

function domain_config_mtls_dir() {
  local output="$1" owner="${2:-}" _dc_mtls_value=""
  require_valid_var_name "$output" || return 1
  is_valid_domain "$owner" && [ "$owner" = "$(normalize_domain "$owner")" ] || return 1
  _dc_mtls_value="${DOMAINS_DIR:-${STATE_DIR}/domains}/${owner}/mtls"
  runtime_state_path_guard_if_declared "$_dc_mtls_value" "domain mTLS directory" || return 1
  printf -v "$output" '%s' "$_dc_mtls_value"
}

function _domain_mtls_resolve() {
  local output="$1" input="${2:-}" owner="${3:-}" root="${DOMAINS_DIR:-${STATE_DIR}/domains}"
  local _dc_mtls_resolved="" relative="" selected_owner="" expected=""
  require_valid_var_name "$output" || return 1
  case "$input" in "$root"/*/mtls) ;; *) return 1 ;; esac
  relative="${input#"$root"/}"; selected_owner="${relative%/mtls}"
  is_valid_domain "$selected_owner" && [ "$selected_owner" = "$(normalize_domain "$selected_owner")" ] || return 1
  [ -z "$owner" ] || [ "$selected_owner" = "$(normalize_domain "$owner")" ] || return 1
  domain_config_mtls_dir expected "$selected_owner" || return 1
  [ "$input" = "$expected" ] || return 1
  runtime_state_path_guard_if_declared "$expected" "owned mTLS directory" || return 1
  _dc_mtls_resolved="$(_runtime_path_resolve_allow_missing "$expected" && printf '.')" || return 1
  _dc_mtls_resolved="${_dc_mtls_resolved%.}"
  printf -v "$output" '%s' "$_dc_mtls_resolved"
}

function domain_config_certificate_dirs() {
  local domain_dir="" dir="" provider="" selection="${1:-declared}"
  if domain_config_certificate_layout; then
    for domain_dir in "${DOMAINS_DIR:-${STATE_DIR}/domains}/"*; do
      [ -d "$domain_dir" ] && [ ! -L "$domain_dir" ] || continue
      is_valid_domain "${domain_dir##*/}" || continue
      for dir in "$domain_dir/certs/"*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/fullchain.pem" ] || continue
        if [ "$selection" != all ] && [ "$(_domain_runtime_get "$dir/certificate.csv" declared yes)" = no ]; then continue; fi
        printf '%s\n' "$dir"
      done
    done
  else
    for provider in selfsigned letsencrypt custom; do
      for dir in "${CERTS_DIR}/${provider}/live/"*; do
        [ -d "$dir" ] && [ -f "$dir/fullchain.pem" ] || continue
        printf '%s\n' "$dir"
      done
    done
  fi
}

function _domain_config_mtls_state_mode() {
  local output="$1" domain="$2" mtls_dir="$3" _dc_mtls_mode=existing prior_enabled=""
  require_valid_var_name "$output" || return 1
  # An accepted enabled authority remains an existing identity even when all
  # its files are missing. Restore must never invent a replacement authority.
  if [ "${DOMAIN_CONFIG_RESTORE_MATERIAL:-false}" != true ]; then
    prior_enabled="$(domain_config_get "${DOMAINS_DIR:-${STATE_DIR}/domains}/$domain/runtime/applied" mtls.csv enabled no)" || return 1
    if [ "$prior_enabled" != yes ] && _mtls_authority_is_empty "$mtls_dir"; then
      _dc_mtls_mode=fresh
    fi
  fi
  printf -v "$output" '%s' "$_dc_mtls_mode"
}

function domain_config_preflight_mtls() {
  local candidate="$1" dir="" domain="" owner="" enabled="" role="" inherit="" mtls_dir="" mtls_mode=""
  for dir in "$candidate"/*; do
    [ -d "$dir/config" ] || continue
    domain="${dir##*/}"
    _domain_config_domain_selected "$domain" || continue
    owner="$domain"
    enabled="$(domain_config_get "$dir/config" mtls.csv enabled no)" || return 1
    # A selected dedicated host may rely on an unselected, already-applied
    # backend authority. Validate that dependency without provisioning it.
    if [ "$enabled" != yes ]; then
      role="$(domain_config_get "$dir/config" domain.csv role)" || return 1
      [ "$role" = dedicated ] || continue
      inherit="$(domain_config_get "$dir/config" inheritance.csv mtls yes)" || return 1
      [ "$inherit" = yes ] || continue
      owner="$(domain_config_get "$dir/config" domain.csv target)" || return 1
      enabled="$(domain_config_get "$candidate/$owner/config" mtls.csv enabled no)" || return 1
    fi
    [ "$enabled" = yes ] || continue
    domain_config_mtls_dir mtls_dir "$owner" || return 1
    _domain_config_mtls_state_mode mtls_mode "$owner" "$mtls_dir" || return 1
    if [ "$mtls_mode" = existing ]; then
      _mtls_validate_authority_state "$mtls_dir" core || return 1
    fi
  done
}

function domain_config_provision_mtls() {
  local candidate="$1" dir="" domain="" enabled="" mtls_dir="" mtls_mode=""
  # Validate every selected existing authority before the first material write,
  # then recheck each one at mutation time through the shared mTLS helpers.
  domain_config_preflight_mtls "$candidate" || return 1
  for dir in "$candidate"/*; do
    [ -d "$dir/config" ] || continue
    domain="${dir##*/}"
    _domain_config_domain_selected "$domain" || continue
    enabled="$(domain_config_get "$dir/config" mtls.csv enabled no)" || return 1
    [ "$enabled" = yes ] || continue
    domain_config_mtls_dir mtls_dir "$domain" || return 1
    _domain_config_mtls_state_mode mtls_mode "$domain" "$mtls_dir" || return 1
    if [ "$mtls_mode" = fresh ]; then
      _generate_backend_ca "$mtls_dir" "$domain" || return 1
    fi
    _init_backend_mtls_state "$mtls_dir" "$mtls_mode" || return 1
    _mtls_chmod_file "$mtls_dir" ca.key 600 || return 1
    [ -f "$mtls_dir/ca.crl" ] || _generate_backend_crl "$mtls_dir" || return 1
  done
}

function _domain_restore_prepare_mtls() (
  local prepared="$1"
  # macOS temporary paths can use /var while the same directory resolves under
  # /private/var. Bind the private state root to the physical path so repeated
  # authority path checks compare the same owned directory.
  prepared="$(cd -P -- "$prepared" && pwd -P)" || return 1
  # Material validation and permitted derived-file recovery happen only in the
  # private restore tree. Disabled material and opaque drafts remain untouched.
  local STATE_DIR="$prepared" DOMAINS_DIR="$prepared/domains"
  local DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_RESTORE_MATERIAL=true DOMAIN_CONFIG_SELECTED_FILE=""
  domain_config_provision_mtls "$prepared/candidate"
)
