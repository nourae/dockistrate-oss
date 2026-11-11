# shellcheck shell=bash

# The aggregate tables are derived caches. A checksum of both their inputs and
# output detects edits to either side without recompiling every unchanged model.
function _domain_config_cache_fingerprint() {
  local root="" domain="" file="" path=""
  local -a files=()
  root="$(domain_config_root)" || return 1
  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    path="$root/$domain/runtime/applied"
    [ -f "$path/domain.csv" ] && [ ! -L "$path" ] || return 1
    for file in "$path"/*.csv; do
      [ -f "$file" ] && [ ! -L "$file" ] || return 1
      files+=("$file")
    done
    file="$root/$domain/runtime/observed.csv"
    if [ -e "$file" ] || [ -L "$file" ]; then
      [ ! -L "$root/$domain/runtime" ] && [ -f "$file" ] && [ ! -L "$file" ] || return 1
      files+=("$file")
    fi
  done < <(domain_config_list applied)
  for file in "$CONFIG_DIR"/*.csv; do
    [ -e "$file" ] || continue
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    files+=("$file")
  done
  if [ "${#files[@]}" -gt 0 ]; then cksum "${files[@]}"; fi
}

function _domain_config_cache_current() {
  local fingerprint="" stored="" marker="$CONFIG_DIR/domain_cache.fingerprint"
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  fingerprint="$(_domain_config_cache_fingerprint)" || return 1
  stored="$(cat "$marker")" || return 1
  [ "$fingerprint" = "$stored" ]
}

function _domain_config_mark_cache() {
  local fingerprint="" temporary="" marker="$CONFIG_DIR/domain_cache.fingerprint"
  fingerprint="$(_domain_config_cache_fingerprint)" || return 1
  make_temp_for_file temporary "$marker" || return 1
  if ! printf '%s\n' "$fingerprint" >"$temporary"; then rm -f "$temporary"; return 1; fi
  finalize_temp_file_with_mode "$marker" "$temporary" 600
}
