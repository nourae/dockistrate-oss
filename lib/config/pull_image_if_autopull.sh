# shellcheck shell=bash

function pull_image_if_autopull() {
  local image="${1:-}" label="${2:-Image}"
  if [ -z "$image" ]; then
    return 0
  fi

  if [ "${SKIP_DOCKER_CHECKS:-}" = "true" ]; then
    echo "[Info] SKIP_DOCKER_CHECKS=true: skipping image pull for $label ($image)."
    return 0
  fi

  local mode="always"
  if [ "$image" = "${NGINX_IMAGE:-}" ]; then
    mode="${NGINX_PULL_MODE:-always}"
  elif [ "$image" = "${CERTBOT_IMAGE:-}" ]; then
    mode="${CERTBOT_PULL_MODE:-always}"
  fi

  if ! image_uses_latest_tag "$image"; then
    echo "[Info] $label image pinned to $image (auto-pull skipped)."
    return 0
  fi

  if [ "$mode" = "if-missing" ]; then
    echo "[Warn] $label image uses :latest with pull policy 'if-missing'; forcing pull to avoid stale images." >&2
    mode="always"
  fi

  case "$mode" in
  never)
    echo "[Info] $label image set to latest but pull policy is 'never'; using local copy if available."
    return 0
    ;;
  if-missing)
    if docker image inspect "$image" >/dev/null 2>&1; then
      echo "[Info] $label image $image already present locally (pull policy: if-missing)."
      return 0
    fi
    ;;
  always | *) ;;
  esac

  if docker pull "$image" >/dev/null 2>&1; then
    echo "[Info] Pulled ${label} image: $image"
  else
    echo "[Warn] Unable to pull ${label} image $image; using local copy if available." >&2
  fi
}
