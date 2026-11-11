# shellcheck shell=bash

function image_uses_latest_tag() {
  local image="${1:-}" last_segment
  [ -n "$image" ] || return 1
  [[ "$image" != *"@"* ]] || return 1
  last_segment="${image##*/}"
  [[ "$last_segment" == *":latest" ]]
}

function image_reference_kind() {
  case "${1:-}" in
  *@*) printf '%s' 'digest-pinned' ;;
  *) printf '%s' 'mutable tag' ;;
  esac
}

# Describe the existing explicit-pull policy without implying offline operation.
function image_pull_policy_note() {
  local image="${1:-}" mode="${2:-if-missing}"
  if image_uses_latest_tag "$image" && [ "$mode" != "never" ]; then
    printf 'mutable latest tag; explicit pull on use (mode=%s)' "$mode"
  else
    printf '%s; explicit pull skipped' "$(image_reference_kind "$image")"
  fi
}
