# shellcheck shell=bash

# Security CLI commands replace proxy workers so established sessions cannot
# retain the previous policy. Manual apply uses the same boundary. Compare
# declarations, not generated text or editable files belonging to other drafts.
function _domain_config_security_row() {
  local filename="${1##*/}" row=""
  case "$filename" in
  settings.csv)
    case "${3:-}" in client_ip_header | acl_policy | acl_status | security_rule_status) ;; *) return 0 ;; esac
    ;;
  inheritance.csv)
    case "${3:-}" in acl | security_rules | headers) ;; *) return 0 ;; esac
    ;;
  esac
  row="$(_domain_config_canonical_row "$@")" || return 1
  [ -n "$row" ] || return 0
  csv_join_row "$_dc_security_domain" "$filename" "$row"
}

function _domain_config_security_signature() {
  local root="$1" mode="$2" directory="" config="" role="" target="" filename="" rows="" _dc_security_domain=""
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  for directory in "$root/"*; do
    [ -e "$directory" ] || [ -L "$directory" ] || continue
    case "$mode" in
    candidate) config="$directory/config" ;;
    applied)
      config="$directory/runtime/applied"
      # Unselected draft-only folders are not active policy. Their names and
      # contents remain the concern of explicit validation/apply of that draft.
      [ -e "$config" ] || [ -L "$config" ] || continue
      ;;
    *) return 1 ;;
    esac
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    _dc_security_domain="${directory##*/}"
    _domain_config_validate_name "$_dc_security_domain" || return 1
    _domain_config_dir_guard "$config" || return 1
    role="$(domain_config_get "$config" domain.csv role)" || return 1
    case "$role" in
    alias | dedicated)
      target="$(domain_config_get "$config" domain.csv target)" || return 1
      csv_join_row "$_dc_security_domain" domain.csv "$role" "$target" || return 1
      ;;
    esac
    for filename in settings.csv inheritance.csv security_rules.csv security_conditions.csv acl.csv; do
      rows="$(_domain_csv_read "$config/$filename" _domain_config_security_row)" || return 1
      [ -z "$rows" ] || printf '%s\n' "$rows" | LC_ALL=C sort || return 1
    done
  done
}

# A boolean result is data: a failed read must never be treated as an ordinary
# reload. Both preview and activation propagate errors from this comparison.
function _domain_config_security_changed() {
  local candidate="$1" before="" after="" root=""
  root="$(domain_config_root)" || return 1
  if [ -e "$root" ] || [ -L "$root" ]; then
    before="$(_domain_config_security_signature "$root" applied)" || return 1
  fi
  after="$(_domain_config_security_signature "$candidate" candidate)" || return 1
  if [ "$before" = "$after" ]; then printf 'false\n'; else printf 'true\n'; fi
}
