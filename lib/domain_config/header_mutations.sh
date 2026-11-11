# shellcheck shell=bash
# These locals are consumed by the mutation, validation, and journal helpers.
# shellcheck disable=SC2034

# These commands deliberately stage the explicit repair before validating the
# old applied cache. No validation bypass is used when publishing the candidate.
function _domain_config_header_arguments() {
  local command="$1" value="" target=""
  shift
  _hc_scope=global _hc_owner="" _hc_action=set _hc_type="" _hc_name="" _hc_value=""
  case "$command" in
  *backend*) _hc_scope=domain; _hc_owner="$(normalize_domain "${1:-}")"; shift || true ;;
  esac
  case "$command" in
  remove-all-*)
    _hc_action=clear
    if [ "$_hc_scope" = domain ] && [ -z "$_hc_owner" ]; then _hc_owner='*'; fi
    ;;
  *hsts | *csp)
    _hc_type=response
    case "$command" in *hsts) _hc_name=Strict-Transport-Security ;; *) _hc_name=Content-Security-Policy ;; esac
    _hc_value="${1:-}"
    value="$(_header_name_identity "$_hc_value")" || return 1
    if [ "$value" = off ]; then _hc_action=remove; fi
    ;;
  *)
    _hc_type="${1:-}"; _hc_name="${2:-}"; _hc_value="${3:-}"
    case "$command" in remove-*) _hc_action=remove ;; esac
    ;;
  esac
  if [ "$_hc_scope" = domain ] && [ "$_hc_owner" != '*' ]; then
    require_valid_domain "$_hc_owner" return || return 1
    # Keep the existing bulk command's primary-backend resolution. Read the
    # applied association directly because its aggregate cache may be stale.
    if [ "$command" = remove-all-backend-headers ]; then
      target="$(domain_config_get "$(domain_config_root)/$_hc_owner/runtime/applied" domain.csv target)" || return 1
      if [ -n "$target" ]; then
        _domain_config_validate_name "$target" || return 1
        _hc_owner="$target"
      fi
    fi
  fi
  [ "$_hc_action" != clear ] || return 0
  if ! _is_valid_header_type "$_hc_type" || ! is_valid_header_name "$_hc_name"; then
    _domain_config_error 'Specify a request/response type and a valid header name.'; return 1;
  fi
  if [ "$_hc_action" = set ]; then
    if [ -z "$_hc_value" ] || ! is_valid_header_value "$_hc_value"; then
      _domain_config_error 'Specify a nonempty header value without control characters.'; return 1;
    fi
  fi
}

function _domain_config_header_guard_owner() {
  local domain="$1" root="" source="" applied=""
  root="$(domain_config_root)" || return 1
  source="$(_domain_config_input_fingerprint "$root/$domain/config")" || return 1
  applied="$(_domain_config_input_fingerprint "$root/$domain/runtime/applied")" || return 1
  if [ "$source" = missing ] || [ "$applied" = missing ] || [ "$source" != "$applied" ]; then
    DOMAIN_CONFIG_PENDING_DOMAIN="$domain"
    _domain_config_error "Unapplied or missing files exist at $root/$domain/config. Review and apply-domain-config $domain before changing its headers."
    return 1
  fi
}

function _domain_config_header_guard() {
  local _hc_scope="" _hc_owner="" _hc_action="" _hc_type="" _hc_name="" _hc_value="" domain=""
  _domain_config_header_arguments "$@" || return 1
  [ "$_hc_scope" = domain ] || return 0
  if [ "$_hc_owner" = '*' ]; then
    while IFS= read -r domain; do
      [ -n "$domain" ] || continue
      _domain_config_header_guard_owner "$domain" || return 1
    done < <(domain_config_list applied)
  else
    _domain_config_header_guard_owner "$_hc_owner"
  fi
}

function _domain_config_header_shared_fingerprint() {
  local file=""
  for file in "$CONFIG_DIR"/*.csv "$CONFIG_DIR/state_schema_version"; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    printf '%s\n' "${file##*/}"
    cksum <"$file" || return 1
  done
}

function _domain_config_header_stage() {
  local work="$1" root="" domain="" file="" before="" after=""
  root="$(domain_config_root)" || return 1
  _domain_config_build_candidate "$work" --applied || return 1
  mkdir -p "$work/shared" "$work/edit-fingerprints" || return 1
  before="$(_domain_config_header_shared_fingerprint)" || return 1
  for file in "$CONFIG_DIR"/*.csv "$CONFIG_DIR/state_schema_version"; do
    [ -f "$file" ] || continue
    cp -p "$file" "$work/shared/${file##*/}" || return 1
  done
  after="$(_domain_config_header_shared_fingerprint)" || return 1
  [ "$before" = "$after" ] || { _domain_config_error 'Shared configuration changed while reading; retry.'; return 1; }
  printf '%s\n' "$before" >"$work/shared-fingerprint" || return 1
  _domain_config_migration_file_fingerprint "$work/shared/custom_headers.csv" >"$work/shared-header-fingerprint" || return 1
  # Bootstrap normally creates this optional empty table. Stage and journal
  # that initialization too, so it cannot be confused with an editor's write.
  if [ ! -e "$work/shared/custom_headers.csv" ]; then
    printf '%s\n' "$STATE_CUSTOM_HEADERS_HEADER" >"$work/shared/custom_headers.csv" || return 1
    _tighten_file_permissions "$work/shared/custom_headers.csv" 600 || return 1
  fi
  : >"$work/changed"
  if [ "$_hc_scope" = global ]; then
    _header_mutate_file "$work/shared/custom_headers.csv" global "$_hc_action" '' "$_hc_type" "$_hc_name" "$_hc_value" || return 1
  else
    for file in "$work/candidate"/*; do
      [ -d "$file" ] || continue
      domain="${file##*/}"
      [ "$_hc_owner" = '*' ] || [ "$_hc_owner" = "$domain" ] || continue
      _domain_config_header_guard_owner "$domain" || return 1
      before="$(_domain_config_input_fingerprint "$root/$domain/config")" || return 1
      # The candidate and editable source must describe the same old revision.
      [ "$before" = "$(cat "$work/source-fingerprints/$domain")" ] || return 1
      printf '%s\n' "$before" >"$work/edit-fingerprints/$domain" || return 1
      _header_mutate_file "$file/config/headers.csv" domain "$_hc_action" "$domain" "$_hc_type" "$_hc_name" "$_hc_value" || return 1
      printf '%s\n' "$domain" >>"$work/changed"
    done
    if [ "$_hc_owner" != '*' ] && [ ! -s "$work/changed" ]; then
      _domain_config_error "Unknown applied domain '$_hc_owner'."; return 1
    fi
  fi
  (
    _domain_config_bind_config "$work/shared" || exit 1
    domain_config_compile "$work/candidate" "$work/compiled" || exit 1
    # Validate the exact compiled artifact that will be published, once.
    _domain_config_validate_compiled_config "$work/compiled"
  )
}

function _domain_config_header_check_snapshot() {
  local work="$1" root="" file="" domain="" expected="" actual=""
  root="$(domain_config_root)" || return 1
  actual="$(_domain_config_header_shared_fingerprint)" || return 1
  [ "$actual" = "$(cat "$work/shared-fingerprint")" ] || {
    _domain_config_error 'Shared configuration changed during header repair; retry.'; return 1;
  }
  for file in "$work/source-fingerprints"/*; do
    [ -f "$file" ] || continue
    domain="${file##*/}"; expected="$(cat "$file")"
    actual="$(_domain_config_input_fingerprint "$root/$domain/runtime/applied")" || return 1
    [ "$actual" = "$expected" ] || {
      _domain_config_error "Applied configuration changed during header repair for $domain; retry."; return 1;
    }
  done
}

# Before publication there is no command mutation to undo. Cancel the empty
# journal instead of replaying its backup over an editor's newer shared inputs.
function _domain_config_header_cancel_unpublished() {
  domain_config_runtime_commit || return 1
  _transaction_clear_installed_traps
  domain_config_runtime_cleanup || return 1
  _begin_transaction_cleanup_failed_start
}

function _domain_config_header_locked() (
  local work="$1" command="$2" started_lock=false domain="" expected="" shared_expected=""
  local _hc_scope="" _hc_owner="" _hc_action="" _hc_type="" _hc_name="" _hc_value=""
  local DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_MUTATION_COMMAND="$2"
  local -a DOMAIN_CONFIG_TRANSACTION_TARGETS=()
  shift 2
  _domain_config_header_arguments "$command" "$@" || return 1
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  domain_config_runtime_recover || return 1
  _domain_config_header_stage "$work" || return 1
  _domain_config_header_check_snapshot "$work" || return 1
  _domain_config_transaction_targets || return 1
  begin_transaction "command_${command}" "${DOMAIN_CONFIG_TRANSACTION_TARGETS[@]}" || return 1
  if ! _domain_config_header_check_snapshot "$work"; then
    _domain_config_header_cancel_unpublished || return 1
    return 1
  fi
  shared_expected="$(cat "$work/shared-header-fingerprint")" || return 1
  _domain_config_migration_file_observe custom_headers.csv "$shared_expected" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    expected="$(cat "$work/edit-fingerprints/$domain")"
    _domain_config_source_publish "$domain" "$work/candidate/$domain/config" "$expected" || return 1
  done <"$work/changed"
  _domain_config_publish_cache "$work/compiled" || return 1
  if [ "$_hc_scope" = global ] || [ "$shared_expected" = missing ]; then
    _domain_config_migration_file_publish custom_headers.csv "$work/shared/custom_headers.csv" "$shared_expected" || return 1
  fi
  domain_config_migration_files_verify "$DOMAIN_CONFIG_RUNTIME_JOURNAL" || return 1
  _domain_config_publish_applied "$work/candidate" "$work/changed" || return 1
  _domain_config_mark_cache || return 1
  # Only the complete validated revision reaches ordinary runtime preparation.
  bootstrap_config_runtime || return 1
  audit_log "$(_run_command_audit_message "$command" "$@")"
  update_nginx_config || return 1
  _domain_config_publish_generated || return 1
  _domain_config_mark_cache || return 1
  _domain_config_source_verify || return 1
  domain_config_migration_files_verify "$DOMAIN_CONFIG_RUNTIME_JOURNAL" || return 1
  create_backup '' "Header_${command}" || return 1
  end_transaction_success || return 1
  printf '[Info] Header configuration updated.\n'
)

function domain_config_header_command() {
  local work="" status=0
  _domain_config_prepare || return 1
  check_dependencies || return 1
  _domain_config_workspace work || return 1
  _domain_config_header_locked "$work" "$@" || status=$?
  _domain_config_workspace_remove "$work" || true
  return "$status"
}
