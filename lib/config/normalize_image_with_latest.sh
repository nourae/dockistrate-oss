# shellcheck shell=bash

function normalize_image_with_latest() {
  local image="${1:-}" last_segment
  [ -n "$image" ] || return 0

  if [[ "$image" != *"@"* ]]; then
    last_segment="${image##*/}"
    if [[ "$last_segment" != *":"* ]]; then
      echo "${image}:latest"
      return 0
    fi
  fi

  echo "$image"
}
