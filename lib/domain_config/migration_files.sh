# shellcheck shell=bash

function _domain_config_migration_file_fingerprint() {
  local file="$1"
  [ ! -L "$file" ] || return 1
  if [ ! -e "$file" ]; then printf 'missing\n'; return 0; fi
  [ -f "$file" ] || return 1
  _sha256_digest_stdin <"$file"
}

# Observe shared input before any transaction writes, including commands that
# leave it unchanged. A failed comparison must still leave the ready record so
# archive replay cannot replace an editor's newer file with its older snapshot.
function _domain_config_migration_file_observe() {
  local name="$1" expected="$2" record="" target=""
  [ "$name" = custom_headers.csv ] || return 1
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 1
  target="$CONFIG_DIR/$name"; record="$DOMAIN_CONFIG_RUNTIME_JOURNAL/shared_sources/$name"
  [ ! -e "$record" ] && [ ! -L "$record" ] || return 1
  (umask 077; mkdir -p "$record") || return 1
  printf '%s\n' "$expected" >"$record/before_fingerprint" || return 1
  printf 'observed\n' >"$record/phase" || return 1
  printf 'ready\n' >"$record/ready" || return 1
  runtime_state_path_guard_if_declared "$target" 'shared configuration' || return 1
  [ "$(_domain_config_migration_file_fingerprint "$target")" = "$expected" ] || {
    _domain_config_error "Shared configuration changed while preparing publication: $target"; return 1;
  }
}

# Header commands snapshot CONFIG_DIR for generated files. This one source file
# instead belongs to its durable shared-source journal, even before publication.
# Called at the leaf replacement step so mirror removal also preserves it.
function _domain_config_shared_file_replay_protected() {
  local destination="$1" record="" target=""
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 1
  case "$destination" in */custom_headers.csv) ;; *) return 1 ;; esac
  record="$DOMAIN_CONFIG_RUNTIME_JOURNAL/shared_sources/custom_headers.csv"
  [ -f "$record/ready" ] && [ ! -L "$record/ready" ] || return 1
  target="$(_rollback_replay_normalize_target "$CONFIG_DIR/custom_headers.csv")" || return 1
  [ "$destination" = "$target" ]
}

# Shared editable files use the same detached-original protection as domain
# sources. They must not be restored blindly from a whole CONFIG_DIR archive.
function _domain_config_migration_file_publish() {
  local name="$1" candidate="$2" expected="$3" record="" target="" observed="" phase=""
  case "$name" in global_settings.csv | backend_docker_opts.csv | security_rules.csv | custom_headers.csv) ;; *) return 1 ;; esac
  [ -n "${DOMAIN_CONFIG_RUNTIME_JOURNAL:-}" ] || return 1
  target="$CONFIG_DIR/$name"; record="$DOMAIN_CONFIG_RUNTIME_JOURNAL/shared_sources/$name"
  runtime_state_path_guard_if_declared "$target" 'shared configuration' || return 1
  if [ -f "$record/ready" ]; then
    IFS= read -r phase <"$record/phase" || return 1
    IFS= read -r observed <"$record/before_fingerprint" || return 1
    [ "$phase" = observed ] && [ "$observed" = "$expected" ] || return 1
  fi
  [ "$(_domain_config_migration_file_fingerprint "$target")" = "$expected" ] || {
    _domain_config_error "Shared configuration changed during publication: $target"; return 1;
  }
  (umask 077; mkdir -p "$record") || return 1
  printf '%s\n' "$expected" >"$record/before_fingerprint" || return 1
  cp -p "$candidate" "$record/after" || return 1
  cp -p "$candidate" "$record/publish" || return 1
  printf 'publishing\n' >"$record/phase" || return 1
  printf 'ready\n' >"$record/ready" || return 1
  if [ "$expected" != missing ]; then
    mv "$target" "$record/detached" || return 1
    [ "$(_domain_config_migration_file_fingerprint "$record/detached")" = "$expected" ] || return 1
  fi
  # A concurrent creator must not be overwritten in the gap after detachment.
  # Link then unlink publishes one regular inode without replacing any target.
  ln "$record/publish" "$target" || return 1
  rm "$record/publish" || return 1
  printf 'published\n' >"$record/phase"
}

function domain_config_migration_files_verify() {
  local journal="$1" record="" name="" expected="" target="" phase=""
  for record in "$journal/shared_sources/"*; do
    [ -f "$record/ready" ] || continue
    name="${record##*/}"
    case "$name" in global_settings.csv | backend_docker_opts.csv | security_rules.csv | custom_headers.csv) ;; *) return 1 ;; esac
    target="$CONFIG_DIR/$name"
    IFS= read -r expected <"$record/before_fingerprint" || return 1
    IFS= read -r phase <"$record/phase" || return 1
    if [ "$phase" = observed ]; then
      [ "$(_domain_config_migration_file_fingerprint "$target")" = "$expected" ] || {
        _domain_config_error "Shared configuration changed during the command: $target"; return 1;
      }
      continue
    fi
    case "$phase" in publishing | published) ;; *) return 1 ;; esac
    if [ -f "$record/detached" ] && [ "$(_domain_config_migration_file_fingerprint "$record/detached")" != "$expected" ]; then
      _domain_config_error "An editor changed the previous shared configuration during publication: $target"; return 1
    fi
    [ "$(_domain_config_migration_file_fingerprint "$target")" = "$(_domain_config_migration_file_fingerprint "$record/after")" ] || {
      _domain_config_error "Shared configuration changed before commit: $target"; return 1;
    }
  done
}

function domain_config_migration_files_rollback() {
  local journal="$1" scope="${2:-all}" record="" name="" expected="" target="" current="" published="" phase="" detached_changed=false failed=false
  case "$scope" in all | settings | headers) ;; *) return 1 ;; esac
  for record in "$journal/shared_sources/"*; do
    [ -f "$record/ready" ] || continue
    name="${record##*/}"
    case "$name" in global_settings.csv | backend_docker_opts.csv | security_rules.csv | custom_headers.csv) ;; *) return 1 ;; esac
    case "$scope:$name" in settings:custom_headers.csv) continue ;; headers:*) [ "$name" = custom_headers.csv ] || continue ;; esac
    target="$CONFIG_DIR/$name"
    IFS= read -r phase <"$record/phase" || return 1
    [ "$phase" != rolled_back ] || continue
    if [ "$phase" = observed ]; then
      # This transaction never published the source. Its current inode and
      # contents belong to the operator, including any concurrent deletion.
      printf 'rolled_back\n' >"$record/phase" || return 1
      continue
    fi
    case "$phase" in publishing | published) ;; *) return 1 ;; esac
    IFS= read -r expected <"$record/before_fingerprint" || return 1
    current="$(_domain_config_migration_file_fingerprint "$target")" || return 1
    published="$(_domain_config_migration_file_fingerprint "$record/after")" || return 1
    detached_changed=false
    if [ -f "$record/detached" ] && [ "$(_domain_config_migration_file_fingerprint "$record/detached")" != "$expected" ]; then detached_changed=true; fi
    if [ "$current" != "$published" ] &&
      { [ "$current" != missing ] || { [ "$name" = custom_headers.csv ] && [ "$phase" = published ]; }; }; then
      if [ "$detached_changed" = true ]; then
        _domain_config_error "Concurrent edits remain at $target and $record/detached; preserved both copies."
        failed=true
      else
        printf 'rolled_back\n' >"$record/phase" || return 1
      fi
      continue
    fi
    if [ "$phase" = publishing ] && [ "$expected" != missing ] && [ ! -e "$record/detached" ]; then continue; fi
    [ "$current" = missing ] || rm "$target" || return 1
    if [ -f "$record/detached" ]; then
      ln "$record/detached" "$target" || return 1
      rm "$record/detached" || return 1
    elif [ "$expected" != missing ]; then
      _domain_config_error "Missing original shared configuration in $record"; return 1
    fi
    printf 'rolled_back\n' >"$record/phase" || return 1
  done
  [ "$failed" = false ]
}

function _domain_config_convert_runtime_metadata() {
  local source="$1" destination="$2" applied="${3:-}" file="" relative="" target="" provider="" id="" value="" key=""
  for file in "$source/runtime/backend.csv" "$source/runtime/observed.csv" "$source/certs/"*/certificate.csv; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    relative="${file#"$source/"}"; target="$destination/$relative"
    (umask 077; mkdir -p "${target%/*}") || return 1
    _domain_runtime_convert_legacy "$file" "$target" || return 1
    case "$relative" in certs/*/certificate.csv) ;; *) continue ;; esac
    provider="$(_domain_runtime_get "$target" provider)" || return 1
    [ "$provider" = custom ] || continue
    id="${relative#certs/}"; id="${id%/certificate.csv}"
    # Missing legacy import metadata inherited accepted options. Materialize
    # that value before a fixed header makes an empty cell explicit.
    for key in source_fullchain source_privkey; do
      value="$(_domain_runtime_get "$file" "$key" __unset__)" || return 1
      if [ "$value" = __unset__ ]; then
        value=""
        [ -z "$applied" ] || value="$(domain_config_certificate_option "$applied" "$id" "$key")" || return 1
        _domain_runtime_put "$target" "$key" "$value" || return 1
      fi
    done
  done
}
