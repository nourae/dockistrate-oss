# shellcheck shell=bash

function domain_config_recover_before_mutation() {
  # A staged repair prepares runtime inside its own transaction after publishing
  # validated inputs. Its live journal is not an interrupted command to replay.
  if [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] && transaction_is_active; then return 0; fi
  case "${1:-}" in
  '' | help | help-update | upgrade-preflight | status | status-all | check-config | list-* | show-* | \
    validate-domain-config | create-backup | tail-proxy-logs) return 0 ;;
  esac
  if domain_config_runtime_recovery_pending; then domain_config_runtime_recover; return $?; fi
  return 0
}

# Listing remains tolerant for status/completion. Applying every draft must
# instead account for malformed visible entries before selecting any domain.
function _domain_config_validate_draft_inventory() {
  local root="${1:-}" path="" domain="" source=""
  [ ! -L "$root" ] || { _domain_config_error "Domain configuration root must not be a symlink: $root"; return 1; }
  for path in "$root"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ ! -L "$path" ] || { _domain_config_error "Domain directory must not be a symlink: $path"; return 1; }
    [ -d "$path" ] || continue
    source="$path/config"
    [ -e "$source" ] || [ -L "$source" ] || continue
    domain="${path##*/}"
    if ! _domain_config_validate_name "$domain"; then
      _domain_config_error "Editable configuration must use a normalized domain folder: $path"; return 1
    fi
    _domain_config_dir_guard "$source" || return 1
    [ -f "$source/domain.csv" ] || {
      _domain_config_error "Missing required editable configuration file: $source/domain.csv"; return 1;
    }
  done
}

function _domain_config_build_candidate() {
  local work="${1:-}" selected="${2:---applied}" root="" domain="" source="" before="" after="" found=false
  root="$(domain_config_root)" || return 1
  if [ "$selected" = --all ]; then _domain_config_validate_draft_inventory "$root" || return 1; fi
  mkdir -p "$work/candidate" "$work/source-fingerprints" || return 1
  : >"$work/selected"
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    _domain_config_validate_name "$domain" || return 1
    source="$root/$domain/runtime/applied"
    if [ "$selected" = --all ] || [ "$selected" = "$domain" ]; then
      found=true
      source="$root/$domain/config"
      [ -f "$source/domain.csv" ] || { _domain_config_error "Missing editable configuration for $domain; removal requires an explicit removal command."; return 1; }
      printf '%s\n' "$domain" >>"$work/selected"
    elif [ ! -f "$source/domain.csv" ]; then
      if ! domain_config_list applied | grep -Fxq "$domain"; then continue; fi
      _domain_config_error "Missing applied configuration for $domain; restore its files before changing active configuration."
      return 1
    fi
    before="$(_domain_config_input_fingerprint "$source")" || return 1
    _domain_config_copy_inputs "$source" "$work/candidate/$domain/config" || return 1
    after="$(_domain_config_input_fingerprint "$source")" || return 1
    [ "$before" = "$after" ] || { _domain_config_error "Configuration changed while reading $domain; retry the operation."; return 1; }
    printf '%s\n' "$before" >"$work/source-fingerprints/$domain"
  done < <(domain_config_list all)
  case "$selected" in
  --all | --applied) ;;
  *) [ "$found" = true ] || { _domain_config_error "No configuration exists for $selected. Run init-domain-config first."; return 1; } ;;
  esac
}

function _domain_config_refresh_cache() {
  domain_config_active || return 0
  [ "${DOMAIN_CONFIG_ACTIVE:-false}" != true ] || return 0
  _domain_config_cache_current && return 0
  local work="" status=0
  _domain_config_workspace work || return 1
  if ! _domain_config_build_candidate "$work" --applied ||
    ! domain_config_compile "$work/candidate" "$work/compiled" ||
    ! _domain_config_publish_cache "$work/compiled" ||
    ! _domain_config_mark_cache; then status=1; fi
  _domain_config_workspace_remove "$work" || true
  if [ "$status" -ne 0 ]; then
    case "${CMD:-}" in
    status | status-all | list-* | show-*)
      printf '[Warn] Showing the last runtime cache because applied domain files are missing or invalid.\n' >&2
      return 0
      ;;
    esac
  fi
  return "$status"
}

function _domain_config_transaction_targets() {
  local root="" domain="" path=""
  root="$(domain_config_root)" || return 1
  # ACME issuer state and issuance receipts are durable external results. Only
  # active serving copies participate in rollback; backups include both.
  DOMAIN_CONFIG_TRANSACTION_TARGETS=("$CONFIG_DIR" "$CERTS_DIR")
  # Editable files deliberately do not participate in filesystem rollback.
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    for path in runtime generated certs mtls; do
      DOMAIN_CONFIG_TRANSACTION_TARGETS+=("$root/$domain/$path")
    done
  done < <(domain_config_list all)
}

function _domain_config_publish_applied() {
  local tree="${1:-}" selection="${2:-}" domain="" root="" destination="" stage="" file="" role=""
  root="$(domain_config_root)" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    destination="$root/$domain/runtime/applied"
    runtime_state_path_guard_if_declared "$destination" "applied configuration" || return 1
    mkdir -p "$root/$domain/runtime" || return 1
    stage="$(umask 077; mktemp -d "$root/$domain/runtime/.applied-XXXXXXXX")" || return 1
    if ! _domain_config_copy_inputs "$tree/$domain/config" "$stage"; then rm -rf "$stage"; return 1; fi
    if [ -e "$destination" ]; then
      _domain_config_dir_guard "$destination" || { rm -rf "$stage"; return 1; }
      rm -rf "$destination" || { rm -rf "$stage"; return 1; }
    fi
    mv "$stage" "$destination" || return 1
    for file in "$destination"/*.csv; do
      [ -f "$file" ] || continue
      _tighten_file_permissions "$file" 600 || return 1
    done
    role="$(domain_config_get "$destination" domain.csv role)" || return 1
    if [ "$role" != backend ]; then
      for file in "$root/$domain/runtime/backend.csv" "$root/$domain/runtime/observed.csv"; do
        [ -e "$file" ] || [ -L "$file" ] || continue
        runtime_state_path_guard_if_declared "$file" "removed backend runtime metadata" || return 1
        safe_rm_f "$file" "$root/$domain/runtime" || return 1
      done
    fi
  done <"$selection"
  _domain_config_write_inventory "$tree"
}

function _domain_config_status_draft_valid() {
  local domain="${1:-}" work="" result=0
  _domain_config_workspace work || return 1
  if ! _domain_config_build_candidate "$work" "$domain" ||
    ! _domain_config_validate_source_tree "$work/candidate"; then result=1; fi
  _domain_config_workspace_remove "$work" || return 1
  return "$result"
}

function domain_config_status() {
  local domain="${1:-}" root="" status=""
  root="$(domain_config_root)" || return 1
  if [ -z "$domain" ]; then
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      status="$(domain_config_status "$domain")" || return 1
      printf '%s: %s\n  Configuration: %s/%s/config\n' "$domain" "$status" "$root" "$domain"
    done < <(domain_config_list all)
    return 0
  fi
  _domain_config_validate_name "$domain" || return 1
  if [ ! -f "$root/$domain/config/domain.csv" ]; then
    if { [ -e "$root/$domain/config" ] || [ -L "$root/$domain/config" ]; } &&
      [ ! -f "$root/$domain/runtime/applied/domain.csv" ] &&
      ! domain_config_list applied | grep -Fxq "$domain"; then
      printf 'invalid draft\n'
    else
      printf 'missing source\n'
    fi
  elif ! domain_config_validate_directory "$domain" "$root/$domain/config" >/dev/null 2>&1; then
    printf 'invalid draft\n'
  elif [ -f "$root/$domain/runtime/applied/domain.csv" ] &&
    _domain_config_same "$root/$domain/config" "$root/$domain/runtime/applied"; then
    if declare -F domain_config_backend_runtime_drift >/dev/null 2>&1 &&
      domain_config_backend_runtime_drift "$domain"; then
      printf 'runtime drift\n'
    else
      printf 'applied\n'
    fi
  elif ! _domain_config_status_draft_valid "$domain" >/dev/null 2>&1; then
    printf 'invalid draft\n'
  elif [ ! -f "$root/$domain/runtime/applied/domain.csv" ]; then
    printf 'draft\n'
  else
    printf 'pending changes\n'
  fi
}
