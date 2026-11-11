# shellcheck shell=bash
# Transaction and runtime flags are dynamically scoped across feature modules.
# Legacy staging deliberately rebinds state roots only inside its subshell.
# shellcheck disable=SC2034,SC2030,SC2031

function _domain_backup_sources() {
  local file="" domain_dir="" part=""
  for file in "$CONFIG_DIR"/*.csv "$CONFIG_DIR/state_schema_version"; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    printf '%s\n' "config/${file##*/}"
  done
  for domain_dir in "$(domain_config_root)"/*; do
    [ -e "$domain_dir" ] || [ -L "$domain_dir" ] || continue
    _domain_config_validate_name "${domain_dir##*/}" || return 1
    [ -d "$domain_dir" ] && [ ! -L "$domain_dir" ] || return 1
    for part in config runtime/applied runtime/backend.csv certs mtls; do
      [ -e "$domain_dir/$part" ] || [ -L "$domain_dir/$part" ] || continue
      printf 'domains/%s/%s\n' "${domain_dir##*/}" "$part"
    done
  done
  for part in acme certificate_receipts; do
    [ -e "$STATE_DIR/shared/$part" ] || [ -L "$STATE_DIR/shared/$part" ] || continue
    printf 'shared/%s\n' "$part"
  done
}

# Public intake rejects links. Only standard Certbot live -> archive links are
# materialized, with exact relative targets recorded for private reconstruction.
function _domain_backup_validate_issuer_link() {
  local relative="$1" target="$2" rest="" lineage="" leaf="" archive_leaf="" stem=""
  case "$relative" in shared/acme/live/*/*) ;; *) return 1 ;; esac
  rest="${relative#shared/acme/live/}"; lineage="${rest%%/*}"; leaf="${rest#*/}"
  case "$lineage" in '' | . | .. | *[!a-zA-Z0-9_.-]*) return 1 ;; esac
  case "$leaf" in cert.pem | chain.pem | fullchain.pem | privkey.pem) ;; *) return 1 ;; esac
  case "$target" in "../../archive/$lineage/"*) ;; *) return 1 ;; esac
  archive_leaf="${target#"../../archive/$lineage/"}"; stem="${leaf%.pem}"
  [[ "$archive_leaf" =~ ^${stem}[0-9]+[.]pem$ ]]
}

function _domain_backup_copy_tree() {
  local source="$1" destination="$2" relative="$3" links_file="$4" child="" name="" target="" expected="" mode="" bytes=""
  _restore_intake_member_name "$relative" >/dev/null || return 1
  if [ -L "$source" ]; then
    target="$(readlink "$source")" || return 1
    _domain_backup_validate_issuer_link "$relative" "$target" || {
      _domain_config_error "Unsupported symlink in backup source: $source"; return 1;
    }
    expected="${source%/live/*}/archive/${target#../../archive/}"
    (
      # Pin the exact declared archive ancestry. Only native macOS /var and
      # /tmp aliases are recognized; arbitrary archive/lineage links remain
      # forbidden. Read the regular leaf from that pinned cwd, never recurse
      # through it if another process replaces it with a directory or link.
      _secure_fs_pin_directory "${expected%/*}" existing || return 1
      local archive_file="./${expected##*/}"
      _secure_fs_stat_path "$archive_file" || return 1
      [ "$SECURE_FS_TYPE" = file ] || return 1
      bytes="$(_restore_intake_size "$archive_file")" || return 1
      mode="$(_restore_intake_file_mode "$archive_file")" || return 1
      mkdir -p "${destination%/*}" || return 1
      _restore_intake_copy_regular "$archive_file" "$destination" "$bytes" 'Backup issuer source' false || return 1
      chmod "$mode" "$destination" || return 1
    ) || return 1
    [ "$(readlink "$source")" = "$target" ] || return 1
    csv_join_row "$relative" "$target" >>"$links_file" || return 1
  elif [ -d "$source" ]; then
    mkdir -p "$destination" || return 1
    for child in "$source"/* "$source"/.[!.]* "$source"/..?*; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      name="${child##*/}"
      _domain_backup_copy_tree "$child" "$destination/$name" "$relative/$name" "$links_file" || return 1
    done
  elif [ -f "$source" ]; then
    bytes="$(_restore_intake_size "$source")" || return 1
    mode="$(_restore_intake_file_mode "$source")" || return 1
    mkdir -p "${destination%/*}" || return 1
    _restore_intake_copy_regular "$source" "$destination" "$bytes" 'Backup source' false || return 1
    chmod "$mode" "$destination" || return 1
  else
    _domain_config_error "Unsupported backup source: $source"
    return 1
  fi
}

function domain_config_backup_write() (
  local destination="$1" sources="" relative="" started_lock=false schema=""
  umask 077
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  sources="$(_domain_backup_sources)" || return 1
  mkdir -p "$destination/config" "$destination/domains" "$destination/shared" || return 1
  printf '%s\n' 'path,target' >"$destination/issuer_links.csv" || return 1
  while IFS= read -r relative; do
    [ -n "$relative" ] || continue
    _domain_backup_copy_tree "$STATE_DIR/$relative" "$destination/$relative" "$relative" "$destination/issuer_links.csv" || return 1
  done <<<"$sources"
  schema="$(state_schema_read_marker_readonly)" || return 1
  case "$schema" in
  2) printf '%s\n' key,value format_version,2 state_schema_version,2 >"$destination/backup_manifest.csv" ;;
  3 | 4 | 5) printf 'format_version,state_schema_version\n%s,%s\n' "$schema" "$schema" >"$destination/backup_manifest.csv" ;;
  *) _domain_config_error "Unsupported domain backup schema: $schema"; return 1 ;;
  esac
)

function domain_config_backup_checksum() (
  local work="" digest=""
  _domain_config_workspace work || return 1
  trap '_domain_config_workspace_remove "$work"' EXIT
  domain_config_backup_write "$work/snapshot" || return 1
  digest="$(cd "$work/snapshot" && _config_checksum .)" || return 1
  printf '%s\n' "$digest"
)

function _domain_backup_manifest_record() {
  case "$3:$4" in 3:3 | 4:4 | 5:5) DOMAIN_BACKUP_FORMAT_VERSION="$3" ;; *) return 1 ;; esac
}

function _domain_backup_manifest_validate() {
  local root="$1" content="" header="" marker=""
  DOMAIN_BACKUP_FORMAT_VERSION=""
  [ -f "$root/backup_manifest.csv" ] && [ ! -L "$root/backup_manifest.csv" ] || return 1
  IFS= read -r header <"$root/backup_manifest.csv" || return 1
  if [ "${header%$'\r'}" = key,value ]; then
    content="$(cat "$root/backup_manifest.csv")" || return 1
    [ "$content" = "$(printf '%s\n' 'key,value' 'format_version,2' 'state_schema_version,2')" ] || {
      _domain_config_error 'Unsupported legacy domain backup manifest.'; return 1;
    }
    DOMAIN_BACKUP_FORMAT_VERSION=2
  else
    csv_read_records "$root/backup_manifest.csv" 'format_version,state_schema_version' _domain_backup_manifest_record singleton || return 1
    case "$DOMAIN_BACKUP_FORMAT_VERSION" in 3 | 4 | 5) ;; *) return 1 ;; esac
  fi
  marker="$(
    _domain_config_bind_config "$root/config"
    state_schema_read_marker_readonly
  )" || return 1
  [ "$marker" = "$DOMAIN_BACKUP_FORMAT_VERSION" ] || {
    _domain_config_error 'Backup manifest and state schema marker disagree.'; return 1;
  }
  [ -d "$root/config" ] && [ -d "$root/domains" ] && [ -d "$root/shared" ]
}

function _domain_backup_restore_issuer_links() {
  local _domain_issuer_root="$1" _domain_issuer_seen=$'\n'
  [ -f "$_domain_issuer_root/issuer_links.csv" ] || return 0
  csv_read_records "$_domain_issuer_root/issuer_links.csv" 'path,target' _domain_backup_restore_issuer_link_record table
}

function _domain_backup_restore_issuer_link_record() {
  local relative="$3" target="$4" destination="" archive=""
  _domain_backup_validate_issuer_link "$relative" "$target" || return 1
  case "$_domain_issuer_seen" in *$'\n'"$relative"$'\n'*) return 1 ;; esac
  _domain_issuer_seen+="$relative"$'\n'
  destination="$_domain_issuer_root/$relative"; archive="$_domain_issuer_root/shared/acme/archive/${target#../../archive/}"
  [ -f "$destination" ] && [ ! -L "$destination" ] && [ -f "$archive" ] && [ ! -L "$archive" ] || return 1
  cmp -s "$destination" "$archive" || return 1
  rm "$destination" && ln -s "$target" "$destination"
}

function domain_config_backup_needs_restore() {
  local root="$1" marker=""
  [ "${CURRENT_STATE_SCHEMA_VERSION:-0}" -lt 2 ] || return 0
  domain_config_active && return 0
  [ ! -e "$root/backup_manifest.csv" ] && [ ! -d "$root/domains" ] || return 0
  if [ -f "$root/config/state_schema_version" ]; then
    IFS= read -r marker <"$root/config/state_schema_version" || true
    case "$marker" in 2 | 3 | 4 | 5) return 0 ;; esac
  fi
  return 1
}

function _domain_restore_build_candidate() {
  local domains="$1" candidate="$2" dir="" domain=""
  mkdir -p "$candidate" || return 1
  for dir in "$domains"/*; do
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    domain="${dir##*/}"; _domain_config_validate_name "$domain" || return 1
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
    if [ -d "$dir/runtime/applied" ]; then
      _domain_config_copy_inputs "$dir/runtime/applied" "$candidate/$domain/config" || return 1
    fi
  done
  domain_config_validate_tree "$candidate"
}

function _domain_restore_validate_inventory() {
  local config="$1" candidate="$2" file="" domain="" line_no=0 seen=$'\n'
  file="$config/domain_inventory.csv"
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r domain || [ -n "$domain" ]; do
    line_no=$((line_no + 1))
    if [ "$line_no" -eq 1 ]; then [ "$domain" = domain ] || return 1; continue; fi
    _domain_config_validate_name "$domain" || return 1
    case "$seen" in *$'\n'"$domain"$'\n'*) return 1 ;; esac
    seen+="$domain"$'\n'
    [ -f "$candidate/$domain/config/domain.csv" ] || {
      _domain_config_error "Backup is missing the applied configuration for $domain."; return 1;
    }
  done <"$file"
  [ "$line_no" -gt 0 ]
}

# Restoring accepts saved certificate material without contacting an issuer.
# Expired certificates remain restorable for an explicit renewal afterwards.
function _domain_restore_prepare_certificates() {
  local prepared="$1" domain_dir="" domain="" material="" file="" row="" rows=""
  local id="" provider="" port="" source_cert="" source_key="" fingerprint="" public_cert="" public_key=""
  for domain_dir in "$prepared/candidate"/*; do
    [ -d "$domain_dir/config" ] || continue
    domain="${domain_dir##*/}"
    for material in "$prepared/domains/$domain/certs/"*; do
      [ -d "$material" ] && [ -f "$material/certificate.csv" ] || continue
      _domain_runtime_put "$material/certificate.csv" declared no || return 1
    done
    file="$domain_dir/config/certificates.csv"
    [ -f "$file" ] || continue
    rows="$(_domain_csv_rows "$file")" || return 1
    while IFS= read -r row || [ -n "$row" ]; do
      [ -n "$row" ] || continue
      csv_parse_line "$row" && [ "$CSV_FIELD_COUNT" -eq 5 ] || return 1
      id="${CSV_FIELDS[0]}"; provider="${CSV_FIELDS[1]}"; port="${CSV_FIELDS[2]}"
      material="$prepared/domains/$domain/certs/$id"
      if [ ! -f "$material/fullchain.pem" ] || [ -L "$material/fullchain.pem" ] ||
        [ ! -f "$material/privkey.pem" ] || [ -L "$material/privkey.pem" ]; then
        _domain_config_error "Backup is missing certificate material for $domain/$id."
        return 1
      fi
      public_cert="$(openssl x509 -in "$material/fullchain.pem" -pubkey -noout 2>/dev/null | _sha256_digest_stdin)" || return 1
      public_key="$(openssl pkey -in "$material/privkey.pem" -pubout 2>/dev/null | _sha256_digest_stdin)" || return 1
      if [ -z "$public_cert" ] || [ "$public_cert" != "$public_key" ]; then
        _domain_config_error "Backup certificate and private key do not match for $domain/$id."
        return 1
      fi
      source_cert="$(domain_config_certificate_option "$domain_dir/config" "$id" source_fullchain)" || return 1
      source_key="$(domain_config_certificate_option "$domain_dir/config" "$id" source_privkey)" || return 1
      fingerprint="$(_domain_cert_fingerprint "$id" "$provider" "$port" "$source_cert" "$source_key")" || return 1
      _domain_cert_write_metadata "$material" "$provider" "$port" || return 1
      _domain_runtime_put "$material/certificate.csv" declared yes || return 1
      _domain_runtime_put "$material/certificate.csv" specification "$fingerprint" || return 1
      _domain_runtime_put "$material/certificate.csv" source_fullchain "$source_cert" || return 1
      _domain_runtime_put "$material/certificate.csv" source_privkey "$source_key" || return 1
    done <<<"$rows"
  done
}

function _domain_restore_prepare_legacy() (
  local source="$1" prepared="$2" details="$3" domain_dir="" domain="" part="" existing_domain_layout=false
  local legacy_certs="$CERTS_DIR" live_identity="$CONFIG_DIR/backend_identity.csv" live_domains="" live_shared="$STATE_DIR/shared"
  live_domains="$(domain_config_root)" || return 1
  _domain_config_details_validate "$details" || return 1
  domain_config_active && existing_domain_layout=true
  # Export may inspect managed containers to recover their images. Never use
  # archived IDs for that inspection, even while the rest of config is staged.
  if [ -f "$live_identity" ] && [ ! -L "$live_identity" ]; then
    cp "$live_identity" "$source/config/backend_identity.csv" || return 1
  else
    printf '%s\n' 'domain,container_id,ownership_token' >"$source/config/backend_identity.csv" || return 1
  fi
  _domain_config_bind_config "$source/config"
  if [ ! -e "$GLOBAL_SETTINGS_FILE" ]; then
    config_reset_defaults
    _save_config_write_rows >"$GLOBAL_SETTINGS_FILE" || return 1
  fi
  _domain_config_export_tree "$prepared/candidate" "$details" || return 1
  domain_config_validate_tree "$prepared/candidate" || return 1
  mkdir -p "$prepared/domains" "$prepared/shared" || return 1
  # A legacy archive contains configuration only. Recover still-local material
  # without modifying its originals, including certificates not yet migrated on
  # an otherwise migrated host. Current owned material wins over retained copies.
  (
    local STATE_DIR="$prepared" DOMAINS_DIR="$prepared/domains"
    domain_config_migrate_certificates "$legacy_certs"
  ) || return 1
  printf 'path,target\n' >"$prepared/issuer_links.csv" || return 1
  if [ "$existing_domain_layout" = true ]; then
    for part in acme certificate_receipts; do
      if [ -d "$live_shared/$part" ]; then
        rm -rf "$prepared/shared/$part" || return 1
        _domain_backup_copy_tree "$live_shared/$part" "$prepared/shared/$part" "shared/$part" "$prepared/issuer_links.csv" || return 1
      fi
    done
    _domain_backup_restore_issuer_links "$prepared" || return 1
  fi
  for domain_dir in "$prepared/candidate"/*; do
    [ -d "$domain_dir/config" ] || continue
    domain="${domain_dir##*/}"
    _domain_config_copy_inputs "$domain_dir/config" "$prepared/domains/$domain/config" || return 1
    _domain_config_copy_inputs "$domain_dir/config" "$prepared/domains/$domain/runtime/applied" || return 1
    for part in certs mtls; do
      if [ -d "$live_domains/$domain/$part" ]; then
        mkdir -p "$prepared/domains/$domain/$part" || return 1
        _domain_backup_copy_tree "$live_domains/$domain/$part" "$prepared/domains/$domain/$part" "domains/$domain/$part" "$prepared/issuer_links.csv" || return 1
      fi
    done
  done
)

function _domain_restore_capture_sources() {
  local prepared="$1" path="" domain=""
  _domain_config_command_snapshot "$prepared" || return 1
  # Include incomplete folders too: a missing domain.csv does not make an
  # operator's draft disposable, nor make a later new folder safe to overwrite.
  for path in "$(domain_config_root)"/*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    [ -d "$path" ] && [ ! -L "$path" ] || return 1
    domain="${path##*/}"; _domain_config_validate_name "$domain" || return 1
    printf '%s\n' "$domain" >>"$prepared/before-domains" || return 1
    # Restore publishes opaque drafts, including regular nested notes or an
    # editor's temporary files. Their complete tree participates in conflicts.
    _domain_config_draft_tree_fingerprint "$path/config" >"$prepared/source-fingerprints/$domain" || return 1
  done
}

function _domain_restore_existing_backend_names() {
  local row="" n=0 domain="" identity="$CONFIG_DIR/backend_identity.csv" path=""
  local -a CSV_FIELDS=()
  local CSV_FIELD_COUNT=0 CSV_PARSE_ERROR=""
  runtime_state_paths_guard_if_declared "$BACKEND_PORTS_FILE" "$identity" || return 1
  if [ -f "$BACKEND_PORTS_FILE" ]; then
    csv_require_header "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER" || return 1
    while IFS= read -r row || [ -n "$row" ]; do
      n=$((n + 1)); [ "$n" -gt 1 ] || continue
      state_backend_ports_parse_line "$row" || return 1
      [ "$STATE_BP_RECORD_TYPE" != backend ] || printf '%s\n' "$STATE_BP_DOMAIN"
    done <"$BACKEND_PORTS_FILE"
  fi
  if [ -e "$identity" ]; then
    _backend_identity_read unused.invalid true || return 1
    n=0
    while IFS= read -r row || [ -n "$row" ]; do
      n=$((n + 1)); [ "$n" -gt 1 ] || continue
      csv_parse_line "$row" || return 1
      printf '%s\n' "${CSV_FIELDS[0]}"
    done <"$identity"
  fi
  for path in "$(domain_config_root)"/*/runtime/applied; do
    [ -d "$path" ] || continue
    _domain_config_dir_guard "$path" || return 1
    domain="${path%/runtime/applied}"; domain="${domain##*/}"
    if [ "$(domain_config_get "$path" domain.csv role)" = backend ]; then printf '%s\n' "$domain"; fi
  done
}

function _domain_restore_require_existing_backends() {
  local candidate="$1" domains="" domain="" role="" missing=""
  domains="$(_domain_restore_existing_backend_names)" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    _domain_config_validate_name "$domain" || return 1
    role="$(domain_config_get "$candidate/$domain/config" domain.csv role)" || return 1
    [ "$role" != backend ] || continue
    case " $missing " in *" $domain "*) ;; *) missing="${missing:+$missing }$domain" ;; esac
  done <<<"$domains"
  [ -n "$missing" ] || return 0
  _domain_config_error "Backup omits or changes existing backends: $missing. Remove each backend explicitly before restoring this backup."
}

function _domain_restore_current_identities() {
  local candidate="$1" destination="$2" dir="" domain="" role="" snapshot_status=0
  printf '%s\n' 'domain,container_id,ownership_token' >"$destination" || return 1
  for dir in "$candidate"/*; do
    [ -d "$dir/config" ] || continue
    domain="${dir##*/}"; role="$(domain_config_get "$dir/config" domain.csv role)" || return 1
    [ "$role" = backend ] || continue
    backend_exists "$domain" || continue
    _backend_identity_read "$domain" true || return 1
    if [ "${SKIP_DOCKER_CHECKS:-}" != true ]; then
      snapshot_status=0
      _backend_container_snapshot "$domain" || snapshot_status=$?
      if [ "$snapshot_status" -eq 2 ]; then
        # A confirmed absent, locally recorded launch may be recreated. The
        # existing helper also rejects an unrelated same-name replacement.
        _domain_runtime_absent_backend_is_replaceable "$domain" || return 1
      elif [ "$snapshot_status" -ne 0 ]; then
        return 1
      fi
    fi
    if [ "$BACKEND_IDENTITY_FOUND" -eq 1 ]; then
      csv_join_row "$domain" "$BACKEND_IDENTITY_ID" "$BACKEND_IDENTITY_TOKEN" >>"$destination" || return 1
    fi
  done
}

function _domain_restore_copy_global_config() {
  local source="$1" file="" name="" skip=false cached="" mode=""
  # nginx_directives.csv also owns editable global and stream-global rows.
  # Restore those archive bytes; compilation rebuilds its domain-scoped rows.
  for file in "$CONFIG_DIR"/*.csv; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    name="${file##*/}"; skip=false
    [ "$name" != backend_identity.csv ] || continue
    while IFS= read -r cached; do [ "$name" != "$cached" ] || skip=true; done < <(_domain_config_cache_files)
    [ "$skip" = false ] || [ "$name" = nginx_directives.csv ] || continue
    safe_rm_f "$file" "$CONFIG_DIR" || return 1
  done
  for file in "$source"/*.csv; do
    [ -f "$file" ] || continue
    name="${file##*/}"; skip=false
    [ "$name" != backend_identity.csv ] || continue
    while IFS= read -r cached; do [ "$name" != "$cached" ] || skip=true; done < <(_domain_config_cache_files)
    [ "$skip" = false ] || [ "$name" = nginx_directives.csv ] || continue
    mode="$(_restore_intake_file_mode "$file")" || return 1
    printf -v mode '%o' "$((8#$mode))"
    mode="$(_permissions_intersect_mode "$mode" 600)" || return 1
    copy_file_atomic "$file" "$CONFIG_DIR/$name" "$mode" || return 1
  done
}

function _domain_restore_publish() {
  local source="$1" prepared="$2" legacy="$3" current_identity="$4" root="" child="" part="" domain="" expected="" candidate=""
  root="$(domain_config_root)"
  _domain_restore_copy_global_config "$source/config" || return 1
  mkdir -p "$root" "$STATE_DIR/shared" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    expected="$(cat "$prepared/source-fingerprints/$domain")" || return 1
    candidate=""
    [ ! -d "$prepared/domains/$domain/config" ] || candidate="$prepared/domains/$domain/config"
    _domain_config_source_publish "$domain" "$candidate" "$expected" tree || return 1
    for part in runtime generated certs mtls; do
      if [ -e "$root/$domain/$part" ]; then safe_rm_rf "$root/$domain/$part" "$root" || return 1; fi
      if [ -d "$prepared/domains/$domain/$part" ]; then
        mkdir -p "$root/$domain" || return 1
        cp -R "$prepared/domains/$domain/$part" "$root/$domain/" || return 1
      fi
    done
    # Runtime observations belong to this host. Reconciliation records them
    # again from the declared backend and this installation's current runtime.
    if [ -d "$root/$domain/runtime" ]; then
      safe_rm_f "$root/$domain/runtime/backend.csv" "$root" || return 1
      safe_rm_f "$root/$domain/runtime/observed.csv" "$root" || return 1
    fi
  done <"$prepared/restore-domains"
  if [ "$legacy" = false ] || [ -d "$prepared/shared/acme" ]; then
    for part in acme certificate_receipts; do
      if [ -e "$STATE_DIR/shared/$part" ]; then safe_rm_rf "$STATE_DIR/shared/$part" "$STATE_DIR/shared" || return 1; fi
      if [ -d "$prepared/shared/$part" ]; then cp -R "$prepared/shared/$part" "$STATE_DIR/shared/" || return 1; fi
    done
  fi
  # A backup never grants ownership of a stale container ID. Only identities
  # verified against this installation before publication survive into restore.
  copy_file_atomic "$current_identity" "$CONFIG_DIR/backend_identity.csv" 600 || return 1
  load_config || return 1
  local SKIP_UPDATE_NGINX_CONFIG=true
  domain_config_reconcile_backends "$prepared/candidate" || return 1
  domain_config_compile "$prepared/candidate" "$prepared/compiled" || return 1
  _domain_config_publish_cache "$prepared/compiled" || return 1
  _domain_config_write_inventory "$prepared/candidate" || return 1
  _state_schema_write_marker 5 || return 1
  SKIP_UPDATE_NGINX_CONFIG=false
  fix_permissions "$root" || return 1
  fix_permissions "$CONFIG_DIR" || return 1
  update_nginx_config || return 1
  _domain_config_publish_generated || return 1
}

function _domain_restore_activate() (
  local source="$1" prepared="$2" legacy="$3" started_lock=false domain="" path="" part="" root=""
  local DOMAIN_CONFIG_ACTIVE=true DOMAIN_CONFIG_CANDIDATE_ROOT=""
  local -a restore_targets=("$CONFIG_DIR" "$STATE_DIR/shared" "$CERTS_DIR")
  DOMAIN_CONFIG_CANDIDATE_ROOT="$prepared/candidate"
  _config_begin_runtime_prep_lock_if_needed started_lock || return 1
  trap '_config_end_runtime_prep_lock_if_started "$started_lock"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  domain_config_runtime_recover || return 1
  _domain_restore_require_existing_backends "$prepared/candidate" || return 1
  root="$(domain_config_root)"
  cp "$prepared/before-domains" "$prepared/restore-domain-input" || return 1
  for path in "$prepared/domains"/*; do
    [ -d "$path" ] || continue
    domain="${path##*/}"; _domain_config_validate_name "$domain" || return 1
    printf '%s\n' "$domain" >>"$prepared/restore-domain-input" || return 1
    if [ ! -f "$prepared/source-fingerprints/$domain" ]; then
      printf 'missing\n' >"$prepared/source-fingerprints/$domain" || return 1
    fi
  done
  LC_ALL=C sort -u "$prepared/restore-domain-input" >"$prepared/restore-domains" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    for part in runtime generated certs mtls; do restore_targets+=("$root/$domain/$part"); done
  done <"$prepared/restore-domains"
  _domain_restore_current_identities "$prepared/candidate" "$prepared/current_identity.csv" || return 1
  begin_transaction restore_domain_backup "${restore_targets[@]}" || return 1
  if [ "${SKIP_DOCKER_CHECKS:-}" != true ]; then
    if ! ensure_no_nginx_container_conflict restore-backup ||
      ! _nginx_prepare_runtime_rollback "$NGINX_IMAGE" || ! domain_config_runtime_capture_proxy; then
      _rollback_handler
      return 1
    fi
  fi
  # Restoring globals can change the image, Docker options, or security policy
  # without changing listener bindings or the certificate projection. Activate
  # all restored settings in the single render, with its normal readiness check.
  local DOCKISTRATE_FORCE_NGINX_RECREATE=true DOCKISTRATE_SECURITY_NGINX_READY_CHECK=true
  if ! _domain_restore_publish "$source" "$prepared" "$legacy" "$prepared/current_identity.csv"; then
    _rollback_handler
    return 1
  fi
  if [ "${SKIP_DOCKER_CHECKS:-}" != true ] && nginx_container_is_managed; then
    check_config || { _rollback_handler; return 1; }
  fi
  _domain_config_source_verify || { _rollback_handler; return 1; }
  end_transaction_success || { _rollback_handler; return 1; }
)

function domain_config_restore_backup() (
  local source="$1" details="${2:-}" backup_ref="${3:-$1}" prepared="" legacy=false marker="" format=""
  local DOMAIN_CONFIG_RESTORE_MATERIAL=true DOMAIN_CONFIG_LEGACY_RECOVERY=true DOMAIN_CONFIG_INPUT_SCHEMA_VERSION=5
  umask 077
  if declare -F _dockistrate_source_deferred_modules >/dev/null 2>&1; then
    _dockistrate_source_deferred_modules || return 1
  fi
  runtime_state_paths_guard_if_declared "$CONFIG_DIR" "$(domain_config_root)" "$STATE_DIR/shared" "$CERTS_DIR" || return 1
  [ -d "$source/config" ] || { _domain_config_error 'Backup has no configuration directory.'; return 1; }
  _domain_config_workspace prepared || return 1
  trap '_domain_config_workspace_remove "$prepared"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _domain_restore_capture_sources "$prepared" || return 1
  if [ -f "$source/backup_manifest.csv" ]; then
    _domain_backup_manifest_validate "$source" || return 1
    format="$DOMAIN_BACKUP_FORMAT_VERSION"
  else
    marker="$(
      _domain_config_bind_config "$source/config"
      state_schema_read_marker_readonly
    )" || return 1
    [ "$marker" = 1 ] || { _domain_config_error 'Domain backup is incomplete: missing backup manifest.'; return 1; }
    legacy=true
    format=1
  fi
  # Verify the historical format before reading current-schema settings. Only
  # this private staged copy is normalized; archive bytes/checksums stay intact.
  _domain_config_convert_shared_config "$source/config" "$prepared/input/config" || return 1
  validate_persisted_config_dir "$prepared/input/config" || return 1
  if [ "$legacy" = false ]; then
    cp -R "$source/domains" "$source/shared" "$prepared/" || return 1
    if [ -f "$source/issuer_links.csv" ]; then cp "$source/issuer_links.csv" "$prepared/issuer_links.csv" || return 1; fi
    _domain_backup_restore_issuer_links "$prepared" || return 1
    if [ "$format" = 2 ] || [ "$format" = 3 ] || [ "$format" = 4 ]; then
      _domain_restore_convert_legacy_domains "$prepared" "$format" || return 1
    else
      _domain_restore_validate_current_records "$prepared" || return 1
    fi
    _domain_restore_normalize_mtls "$prepared" || return 1
    # Custom material must be readable by strict current-schema validation,
    # including imports whose original external files are no longer available.
    _domain_restore_normalize_runtime_metadata "$prepared" || return 1
    # Restoring must be able to repair malformed current global settings. The
    # archived globals govern candidate validation; this binding never reaches
    # runtime reconciliation or container identity resolution.
    (
      local DOMAIN_CONFIG_RESTORE_MATERIAL_ROOT="$prepared/domains"
      local DOMAIN_CONFIG_LEGACY_RECOVERY=false
      _domain_config_bind_config "$prepared/input/config"
      load_config || return 1
      _domain_restore_build_candidate "$prepared/domains" "$prepared/candidate"
    ) || return 1
    _domain_restore_validate_inventory "$prepared/input/config" "$prepared/candidate" || return 1
  else
    _domain_restore_prepare_legacy "$prepared/input" "$prepared" "$details" || return 1
    _domain_restore_normalize_runtime_metadata "$prepared" || return 1
  fi
  _domain_restore_prepare_certificates "$prepared" || return 1
  _domain_restore_prepare_mtls "$prepared" || return 1
  _domain_restore_require_existing_backends "$prepared/candidate" || return 1
  if declare -F check_dependencies >/dev/null 2>&1; then check_dependencies || return 1; fi
  _domain_restore_activate "$prepared/input" "$prepared" "$legacy" || return $?
  if declare -F audit_log >/dev/null 2>&1; then audit_log "restore-backup $backup_ref" || true; fi
  if declare -F log_msg >/dev/null 2>&1; then log_msg "Restored backup from $backup_ref" || true; fi
  printf '[Info] Restored domain configuration. Pending drafts remain unapplied.\n'
)
