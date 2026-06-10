# shellcheck shell=bash

function image_uses_latest_tag() {
  local image="${1:-}" last_segment
  [ -n "$image" ] || return 1
  [[ "$image" != *"@"* ]] || return 1
  last_segment="${image##*/}"
  [[ "$last_segment" == *":latest" ]]
}
