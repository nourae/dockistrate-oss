# shellcheck shell=bash

function _domain_restore_convert_legacy_domains() {
  local prepared="$1" version="$2" directory="" domain="" part="" source="" destination="" layout=flat
  for directory in "$prepared/domains/"*; do
    [ -e "$directory" ] || [ -L "$directory" ] || continue
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    domain="${directory##*/}"; _domain_config_validate_name "$domain" || return 1
    for part in config runtime/applied; do
      source="$directory/$part"
      [ -e "$source" ] || [ -L "$source" ] || continue
      destination="$prepared/converted/$domain/$part"
      layout=flat
      if [ "$version" = 4 ] && [ "$part" = config ]; then layout=tree; fi
      _domain_csv_convert_directory "$version" "$source" "$destination" "$layout" || return 1
      _domain_config_source_guard "$layout" "$source" || return 1
      rm -rf "$source" || return 1
      mkdir -p "${source%/*}" || return 1
      mv "$destination" "$source" || return 1
    done
  done
}

function _domain_restore_validate_current_records() (
  local prepared="$1" directory="" part="" file="" header=""
  local DOMAIN_CONFIG_LEGACY_RECOVERY=false
  for directory in "$prepared/domains/"*; do
    [ -e "$directory" ] || [ -L "$directory" ] || continue
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    for part in config runtime/applied; do
      [ -e "$directory/$part" ] || [ -L "$directory/$part" ] || continue
      # Current-format drafts are operator bytes, including unfinished edits.
      # Only the accepted snapshot is eligible to drive restored runtime.
      if [ "$part" = config ]; then
        _domain_config_draft_tree_guard "$directory/$part" || return 1
        continue
      fi
      _domain_config_dir_guard "$directory/$part" || return 1
      for file in "$directory/$part/"*.csv; do
        [ -f "$file" ] || continue
        _domain_csv_read "$file" _domain_runtime_validate_record || return 1
      done
    done
    for file in "$directory/runtime/backend.csv" "$directory/runtime/observed.csv" "$directory/certs/"*/certificate.csv; do
      [ -e "$file" ] || [ -L "$file" ] || continue
      header="$(_domain_runtime_header "$file")" || return 1
      csv_read_records "$file" "$header" _domain_runtime_validate_record singleton || return 1
    done
  done
)

# Old snapshots stored the source checkout's owned mTLS path. Its prefix is
# metadata only: never inspect it or use it to locate material on this host.
function _domain_restore_mtls_directory_record() {
  local directory="${4:-}"
  case "${3:-}" in '' | yes | no) ;; *) return 1 ;; esac
  case "$directory" in /*/domains/"$_dc_restore_mtls_domain"/mtls) ;; *) return 1 ;; esac
  case "$directory" in *[[:cntrl:]]* | *//* | */./* | */../*) return 1 ;; esac
  printf '%s' "$directory"
}

function _domain_restore_normalize_mtls() {
  local prepared="$1" directory="" applied="" draft="" old_path="" draft_path="" _dc_restore_mtls_domain=""
  for directory in "$prepared/domains/"*; do
    [ -d "$directory" ] || continue
    _dc_restore_mtls_domain="${directory##*/}"
    _domain_config_validate_name "$_dc_restore_mtls_domain" || return 1
    applied="$directory/runtime/applied/mtls.csv"
    [ -f "$applied" ] || continue
    # Other values remain subject to ordinary strict candidate validation.
    old_path="$(csv_read_records "$applied" 'enabled,directory' _domain_restore_mtls_directory_record singleton 2>/dev/null)" || continue
    [ -n "$old_path" ] || continue
    draft="$directory/config/mtls.csv"
    if [ -f "$draft" ]; then
      # Only rebind the same saved location. An unrelated path-only edit or
      # unfinished draft must survive intact, even if it cannot yet be applied.
      if draft_path="$(csv_read_records "$draft" 'enabled,directory' _domain_restore_mtls_directory_record singleton 2>/dev/null)" &&
        [ "$draft_path" = "$old_path" ]; then
        _domain_csv_set "$draft" directory '' || return 1
      fi
    fi
    _domain_csv_set "$applied" directory '' || return 1
  done
}

function _domain_restore_normalize_runtime_metadata() {
  local prepared="$1" directory="" domain="" file="" relative="" applied=""
  for directory in "$prepared/domains/"*; do
    [ -d "$directory" ] || continue
    domain="${directory##*/}"
    applied="$directory/runtime/applied"
    [ -d "$applied" ] || applied=""
    _domain_config_convert_runtime_metadata "$directory" "$prepared/metadata/$domain" "$applied" || return 1
  done
  for file in "$prepared/metadata/"*/runtime/*.csv "$prepared/metadata/"*/certs/*/certificate.csv; do
    [ -f "$file" ] || continue
    relative="${file#"$prepared/metadata/"}"
    copy_file_atomic "$file" "$prepared/domains/$relative" 600 || return 1
  done
}
