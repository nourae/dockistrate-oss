# shellcheck shell=bash

function set_certbot_image() {
  local image="${1:-}" pull_mode="${2:-}"
  if [ -z "$image" ]; then
    echo "${GLOBAL_SETTINGS_USAGE_PREFIX} set-certbot-image <image[:tag]> [pull_mode]" >&2
    return 1
  fi
  if [ -n "$pull_mode" ] && [[ ! "$pull_mode" =~ ^(always|if-missing|never)$ ]]; then
    echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid pull mode: $pull_mode (expected always|if-missing|never)" >&2
    return 1
  fi
  if ! is_valid_image_ref "$image"; then
    echo "${GLOBAL_SETTINGS_ERROR_PREFIX} Invalid image reference: $image" >&2
    return 1
  fi
  local normalized_image
  normalized_image="$(normalize_image_with_latest "$image")" || return 1
  if [ "$normalized_image" != "$image" ]; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} No tag supplied; defaulting to $normalized_image."
  fi
  CERTBOT_IMAGE="$normalized_image"
  [ -n "$pull_mode" ] && CERTBOT_PULL_MODE="$pull_mode"
  save_config || return 1
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} CERTBOT_IMAGE set to $CERTBOT_IMAGE and saved in $GLOBAL_SETTINGS_FILE."
  echo "${GLOBAL_SETTINGS_INFO_PREFIX} CERTBOT pull mode: ${CERTBOT_PULL_MODE}"
  if image_uses_latest_tag "$CERTBOT_IMAGE"; then
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} Latest-tagged Certbot image will be auto-pulled according to pull mode (${CERTBOT_PULL_MODE})."
  else
    echo "${GLOBAL_SETTINGS_INFO_PREFIX} Pinned Certbot image will skip auto-pull; Docker will use the specified reference."
  fi
}
