# shellcheck shell=bash

function state_schema_version_file() {
  STATE_SCHEMA_VERSION_FILE="${CONFIG_DIR}/state_schema_version"
  printf '%s' "$STATE_SCHEMA_VERSION_FILE"
}

function _state_schema_normalize_version() {
  local version="${1:-}" source="${2:-state schema version}" normalized

  if ! [[ "$version" =~ ^[0-9]+$ ]]; then
    echo "[Error] Invalid ${source}: expected a positive numeric value." >&2
    return 1
  fi

  normalized="$version"
  while [ "${normalized#0}" != "$normalized" ]; do
    normalized="${normalized#0}"
  done

  if [ -z "$normalized" ]; then
    echo "[Error] Invalid ${source}: expected a positive numeric value." >&2
    return 1
  fi

  if [ "${#normalized}" -gt 9 ]; then
    echo "[Error] Invalid ${source}: value is too large." >&2
    return 1
  fi

  printf '%s\n' "$normalized"
}

function _state_schema_read_marker_for_supported() {
  local supported_version="${1:-}" source="${2:-supported state schema version}"
  local marker_file first_line="" extra_line="" has_extra=false current_version
  marker_file="$(state_schema_version_file)"
  current_version="$(_state_schema_normalize_version "$supported_version" "$source")" || return 1

  if [ -e "$marker_file" ] && [ ! -f "$marker_file" ]; then
    echo "[Error] State schema marker is not a regular file: ${marker_file}" >&2
    return 1
  fi

  if [ ! -e "$marker_file" ]; then
    printf '%s\n' "1"
    return 0
  fi

  {
    IFS= read -r first_line || true
    if IFS= read -r extra_line || [ -n "$extra_line" ]; then
      has_extra=true
    fi
  } <"$marker_file"
  first_line="${first_line%$'\r'}"

  if [ "$has_extra" = true ]; then
    echo "[Error] Invalid state schema marker in ${marker_file}: expected a single numeric value." >&2
    return 1
  fi

  first_line="$(_state_schema_normalize_version "$first_line" "state schema version in ${marker_file}")" || return 1

  if [ "$first_line" -gt "$current_version" ]; then
    echo "[Error] Unsupported state schema version ${first_line}; this Dockistrate release supports up to ${current_version}." >&2
    return 1
  fi

  printf '%s\n' "$first_line"
}

function _state_schema_read_marker() {
  _state_schema_read_marker_for_supported "$CURRENT_STATE_SCHEMA_VERSION" "current state schema version"
}

function state_schema_read_marker_readonly() {
  _state_schema_read_marker
}

function _state_schema_write_marker() {
  local version="${1:-}" marker_file tmp_file=""
  marker_file="$(state_schema_version_file)"

  version="$(_state_schema_normalize_version "$version" "state schema version")" || return 1

  mkdir -p "$(dirname "$marker_file")" || return 1
  make_temp_for_file tmp_file "$marker_file" || return 1
  if ! printf '%s\n' "$version" >"$tmp_file"; then
    rm -f "$tmp_file"
    echo "[Error] Failed to write state schema marker: ${marker_file}" >&2
    return 1
  fi

  if declare -F finalize_temp_file_with_mode >/dev/null 2>&1; then
    finalize_temp_file_with_mode "$marker_file" "$tmp_file" 640 || {
      rm -f "$tmp_file"
      return 1
    }
  else
    mv -f "$tmp_file" "$marker_file" || {
      rm -f "$tmp_file"
      return 1
    }
  fi
}

function _state_schema_migrate() {
  local from_version="${1:-}" target_version="${2:-}"

  from_version="$(_state_schema_normalize_version "$from_version" "source state schema version")" || return 1
  target_version="$(_state_schema_normalize_version "$target_version" "target state schema version")" || return 1

  while [ "$from_version" -lt "$target_version" ]; do
    case "$from_version" in
    1 | 2 | 3 | 4)
      echo "[Error] State schema ${from_version} requires explicit migration. Run ./dockistrate.sh migrate-state --dry-run, then migrate-state." >&2
      return 1
      ;;
    *)
      echo "[Error] No state schema migration is available from version ${from_version}." >&2
      return 1
      ;;
    esac
  done
}

function state_schema_bootstrap() {
  local schema_version current_version marker_file marker_exists=false

  marker_file="$(state_schema_version_file)"
  if [ -e "$marker_file" ]; then
    marker_exists=true
  fi
  schema_version="$(_state_schema_read_marker)" || return 1
  current_version="$(_state_schema_normalize_version "$CURRENT_STATE_SCHEMA_VERSION" "current state schema version")" || return 1

  if [ "$marker_exists" = false ] && [ "$current_version" = 5 ] && ! _state_schema_has_legacy_domains; then
    _state_schema_write_marker "$current_version"
    return
  fi

  if [ "$schema_version" -lt "$current_version" ]; then
    _state_schema_migrate "$schema_version" "$current_version" || return 1
    _state_schema_write_marker "$current_version"
    return
  fi

  if [ "$marker_exists" = false ]; then
    _state_schema_write_marker "$current_version"
  fi
}

function _state_schema_has_legacy_domains() {
  local file="" path="" header=""
  if [ -f "${CONFIG_DIR}/global_settings.csv" ]; then
    IFS= read -r header <"${CONFIG_DIR}/global_settings.csv" || true
    [ "${header%$'\r'}" != setting_key,setting_value ] || return 0
  fi
  for file in "${CONFIG_DIR}"/backend_*.csv "${CONFIG_DIR}/dedicated_host_inheritance.csv" \
    "${CONFIG_DIR}/security_rules.csv" "${CONFIG_DIR}/security_ip_rules.csv"; do
    if [ -f "$file" ] && awk 'NR > 1 && length($0) {found=1} END {exit !found}' "$file"; then return 0; fi
  done
  # Global directive rows alone do not imply a legacy domain configuration.
  file="${CONFIG_DIR}/nginx_directives.csv"
  if [ -f "$file" ] && awk -F, 'NR > 1 && $2 != "" {found=1} END {exit !found}' "$file"; then return 0; fi
  for path in "${CERTS_DIR:-${STATE_DIR}/certs}"/*/live/* "${CERTS_DIR:-${STATE_DIR}/certs}"/mtls/*; do
    [ ! -e "$path" ] || return 0
  done
  return 1
}

function state_schema_require_runtime_layout() {
  local marker="" version=""
  marker="$(state_schema_version_file)"
  version="$(_state_schema_read_marker)" || return 1
  if [ "$version" -lt "$CURRENT_STATE_SCHEMA_VERSION" ]; then
    if [ -e "$marker" ] || _state_schema_has_legacy_domains; then
      echo "[Error] Existing state requires migration. Run ./dockistrate.sh migrate-state --dry-run, then migrate-state." >&2
      return 1
    fi
  fi
}
