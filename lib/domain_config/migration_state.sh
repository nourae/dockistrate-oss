# shellcheck shell=bash

# Private staging is shared by explicit migration and legacy backup intake.
# It never edits the input directory, queries containers or applies a draft.
function _domain_config_convert_shared_config() {
  local source="$1" destination="$2" file="" name=""
  (umask 077; mkdir -p "$destination") || return 1
  for file in "$source"/*.csv; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    cp -p "$file" "$destination/${file##*/}" || return 1
  done
  if [ -f "$source/state_schema_version" ]; then cp -p "$source/state_schema_version" "$destination/" || return 1; fi
  for name in global_settings.csv backend_docker_opts.csv security_rules.csv; do
    [ -f "$source/$name" ] || continue
    case "$name" in
    global_settings.csv) _global_settings_convert_legacy "$source/$name" "$destination/$name" || return 1 ;;
    backend_docker_opts.csv) _backend_docker_opts_convert_legacy "$source/$name" "$destination/$name" || return 1 ;;
    security_rules.csv) _domain_security_convert_aggregate "$source/$name" "$destination/$name" || return 1 ;;
    esac
    _tighten_file_permissions "$destination/$name" 640 || return 1
  done
}

function _domain_config_migration_build() (
  local work="$1" details="${2:-}" version="" root="" path="" domain="" before="" after="" applied="" name="" layout=flat
  local DOMAIN_CONFIG_MIGRATING=true DOMAIN_CONFIG_LEGACY_RECOVERY=true DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  version="$(state_schema_read_marker_readonly)" || return 1
  case "$version" in 1 | 2 | 3 | 4) ;; *) _domain_config_error "Unsupported migration source schema: $version"; return 1 ;; esac
  root="$(domain_config_root)"
  [ "$version" != 4 ] || layout=tree
  _domain_config_details_validate "$details" || return 1
  (umask 077; mkdir -p "$work/candidate" "$work/drafts" "$work/runtime-data" "$work/source-fingerprints" "$work/shared-fingerprints") || return 1
  printf '%s\n' "$version" >"$work/from-schema" || return 1
  for name in global_settings.csv backend_docker_opts.csv security_rules.csv; do
    _domain_config_migration_file_fingerprint "$CONFIG_DIR/$name" >"$work/shared-fingerprints/$name" || return 1
  done
  _domain_config_convert_shared_config "$CONFIG_DIR" "$work/shared-config" || return 1
  for name in global_settings.csv backend_docker_opts.csv security_rules.csv; do
    [ "$(_domain_config_migration_file_fingerprint "$CONFIG_DIR/$name")" = "$(cat "$work/shared-fingerprints/$name")" ] || {
      _domain_config_error "Shared configuration changed while preparing migration: $name"; return 1;
    }
  done
  if [ "$version" = 1 ]; then
    (
      _domain_config_bind_config "$work/shared-config"
      [ ! -s "$GLOBAL_SETTINGS_FILE" ] || load_config || return 1
      _domain_config_export_tree "$work/candidate" "$details"
    ) || return 1
    for path in "$work/candidate/"*; do
      [ -d "$path/config" ] || continue
      domain="${path##*/}"
      [ ! -e "$root/$domain/config" ] && [ ! -L "$root/$domain/config" ] || {
        _domain_config_error "Schema-1 migration would overwrite an existing domain draft: $domain"; return 1;
      }
      _domain_config_copy_inputs "$path/config" "$work/drafts/$domain/config" || return 1
      printf 'missing\n' >"$work/source-fingerprints/$domain" || return 1
    done
  else
    [ ! -L "$root" ] || return 1
    for path in "$root/"*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      [ -d "$path" ] && [ ! -L "$path" ] || return 1
      domain="${path##*/}"; _domain_config_validate_name "$domain" || return 1
      before="$(_domain_config_source_fingerprint "$layout" "$path/config")" || return 1
      printf '%s\n' "$before" >"$work/source-fingerprints/$domain" || return 1
      if [ "$before" != missing ]; then
        _domain_csv_convert_directory "$version" "$path/config" "$work/drafts/$domain/config" "$layout" || return 1
        after="$(_domain_config_source_fingerprint "$layout" "$path/config")" || return 1
        [ "$before" = "$after" ] || { _domain_config_error "Draft changed while reading $domain"; return 1; }
      fi
      applied=""
      if [ -e "$path/runtime/applied" ] || [ -L "$path/runtime/applied" ]; then
        _domain_config_dir_guard "$path/runtime/applied" || return 1
        _domain_csv_convert_directory "$version" "$path/runtime/applied" "$work/candidate/$domain/config" || return 1
        applied="$work/candidate/$domain/config"
      fi
      _domain_config_convert_runtime_metadata "$path" "$work/runtime-data/$domain" "$applied" || return 1
    done
    _domain_restore_validate_inventory "$CONFIG_DIR" "$work/candidate" || return 1
  fi
  (
    _domain_config_bind_config "$work/shared-config"
    [ ! -s "$GLOBAL_SETTINGS_FILE" ] || load_config || return 1
    domain_config_validate_tree "$work/candidate"
  ) || return 1
)

function _domain_config_migrate_locked() (
  local work="$1" details="${2:-}" root="" path="" domain="" part="" name="" expected="" relative="" version="" started_lock=false layout=flat
  local DOMAIN_CONFIG_ACTIVE=false DOMAIN_CONFIG_MIGRATING=true DOMAIN_CONFIG_LEGACY_RECOVERY=true DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  local -a migration_targets=()
  root="$(domain_config_root)"
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  domain_config_runtime_recover || return 1
  version="$(state_schema_read_marker_readonly)" || return 1
  if [ "$version" = 5 ]; then printf '[Info] State already uses schema 5.\n'; return 0; fi
  _domain_config_migration_build "$work" "$details" || return 1
  [ "$version" != 4 ] || layout=tree
  migration_targets=("$CONFIG_DIR/state_schema_version" "$CONFIG_DIR/domain_inventory.csv" "$CONFIG_DIR/domain_cache.fingerprint")
  if [ "$version" = 1 ]; then migration_targets+=("$STATE_DIR/shared"); fi
  for path in "$work/candidate/"* "$work/drafts/"* "$work/runtime-data/"*; do
    [ -d "$path" ] || continue
    domain="${path##*/}"
    for part in runtime generated; do migration_targets+=("$root/$domain/$part"); done
    if [ "$version" = 1 ]; then
      migration_targets+=("$root/$domain/certs" "$root/$domain/mtls")
    fi
  done
  for path in "$work/runtime-data/"*/certs/*/certificate.csv; do
    [ -f "$path" ] || continue
    relative="${path#"$work/runtime-data/"}"
    migration_targets+=("$root/$relative")
  done
  DOMAIN_CONFIG_ACTIVE=true
  begin_transaction migrate_state "${migration_targets[@]}" || return 1
  for name in global_settings.csv backend_docker_opts.csv security_rules.csv; do
    [ -f "$work/shared-config/$name" ] || continue
    expected="$(cat "$work/shared-fingerprints/$name")" || return 1
    _domain_config_migration_file_publish "$name" "$work/shared-config/$name" "$expected" || return 1
  done
  [ ! -s "$GLOBAL_SETTINGS_FILE" ] || load_config || return 1
  if [ "$version" = 1 ]; then domain_config_migrate_certificates || return 1; fi
  for path in "$work/drafts/"*; do
    [ -d "$path/config" ] || continue
    domain="${path##*/}"; expected="$(cat "$work/source-fingerprints/$domain")" || return 1
    _domain_config_source_publish "$domain" "$path/config" "$expected" "$layout" || return 1
  done
  : >"$work/selected"
  for path in "$work/candidate/"*; do
    [ -d "$path/config" ] || continue
    domain="${path##*/}"; printf '%s\n' "$domain" >>"$work/selected" || return 1
  done
  _domain_config_publish_applied "$work/candidate" "$work/selected" || return 1
  for path in "$work/runtime-data/"*/runtime/*.csv "$work/runtime-data/"*/certs/*/certificate.csv; do
    [ -f "$path" ] || continue
    relative="${path#"$work/runtime-data/"}"
    copy_file_atomic "$path" "$root/$relative" 600 || return 1
  done
  if [ "$version" = 1 ]; then
    for path in "$work/candidate/"*; do
      [ -f "$path/config/backend.csv" ] || continue
      domain="${path##*/}"
      [ "$(domain_config_get "$path/config" domain.csv role)" = backend ] || continue
      copy_file_atomic "$path/config/backend.csv" "$root/$domain/runtime/backend.csv" 600 || return 1
      if [ "${SKIP_DOCKER_CHECKS:-}" != true ] && _backend_container_snapshot "$domain" >/dev/null 2>&1; then
        domain_config_record_observed_backend "$domain" || return 1
      fi
    done
  fi
  # This republishes diagnostics only; the Nginx serving configuration, Docker
  # objects, certificate bytes and issuance receipts are never changed here.
  _domain_config_publish_generated || return 1
  _domain_config_source_verify || return 1
  domain_config_migration_files_verify "$DOMAIN_CONFIG_RUNTIME_JOURNAL" || return 1
  _state_schema_write_marker 5 || return 1
  _domain_config_mark_cache || return 1
  end_transaction_success || return 1
  printf '[Info] State migrated to schema 5. Running containers and proxy configuration were not changed.\n'
)

function migrate_state() {
  local dry_run=false details="" work="" status=0 version="" path=""
  local DOMAIN_CONFIG_MIGRATING=true DOMAIN_CONFIG_LEGACY_RECOVERY=true DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  while [ "$#" -gt 0 ]; do
    case "$1" in
    --dry-run) dry_run=true; shift ;;
    --backend-details) require_option_value "$@" || return 2; details="$2"; shift 2 ;;
    *) _domain_config_error 'Usage: migrate-state [--dry-run] [--backend-details <csv>]'; return 2 ;;
    esac
  done
  # Recovery must precede reading potentially half-published shared settings.
  if declare -F _dockistrate_source_deferred_modules >/dev/null 2>&1; then
    _dockistrate_source_deferred_modules || return 1
  fi
  runtime_state_path_guard_if_declared "$(domain_config_root)" 'migration domain root' || return 1
  version="$(state_schema_read_marker_readonly)" || return 1
  if [ "$version" = 5 ] && ! domain_config_runtime_recovery_pending; then printf '[Info] State already uses schema 5.\n'; return 0; fi
  _domain_config_workspace work || return 1
  if [ "$dry_run" = true ]; then
    if domain_config_runtime_recovery_pending; then
      _domain_config_error 'Unfinished transaction recovery is required before migration; dry-run made no changes.'
      status=1
    elif _domain_config_migration_build "$work" "$details"; then
      printf '[Info] Migration preflight passed (schema %s -> 5). No state or containers were changed.\n' "$version"
      printf '  Add explicit require actions to existing security rules; preserve draft/applied separation.\n'
      if [ "$version" -lt 4 ]; then printf '  Merge listener options into ports.csv and import paths into certificates.csv; remove the split option files.\n'; fi
      for path in "$work/candidate/"*; do [ ! -d "$path" ] || printf '  %s\n' "${path##*/}"; done
    else
      _domain_config_error 'Migration preflight failed; existing state is unchanged. Review the reported files or supply missing backend details.'
      status=1
    fi
  else
    _domain_config_migrate_locked "$work" "$details" || status=$?
  fi
  _domain_config_workspace_remove "$work" || true
  return "$status"
}
