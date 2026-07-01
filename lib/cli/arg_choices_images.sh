# shellcheck shell=bash

: "${CLI_PROMPT_CACHE_TOKEN:=0}"
CLI_DOCKER_IMAGES_CACHE_TOKEN=""
CLI_DOCKER_IMAGES_CACHE_VALUE=""

function _cli_prompt_cached_docker_images() {
  local cache_token="${CLI_PROMPT_CACHE_TOKEN:-0}"
  if [ "${CLI_DOCKER_IMAGES_CACHE_TOKEN:-}" = "$cache_token" ]; then
    printf '%s' "${CLI_DOCKER_IMAGES_CACHE_VALUE:-}"
    return 0
  fi

  local image_lines=""
  if command -v docker >/dev/null 2>&1; then
    image_lines="$(docker image ls --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.CreatedSince}}|{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null | sort -u || true)"
    if [ -z "$image_lines" ]; then
      image_lines="$(docker image ls --format '{{.Repository}}:{{.Tag}}|{{.ID}}|{{.CreatedSince}}' 2>/dev/null | sort -u || true)"
    fi
  fi

  CLI_DOCKER_IMAGES_CACHE_TOKEN="$cache_token"
  CLI_DOCKER_IMAGES_CACHE_VALUE="$image_lines"
  printf '%s' "$image_lines"
}

function __arg_choices_image() {
  local cmd="$1"
  # Suggest local images (with digest/created metadata) and allow manual entry
  # For update-backend, add a Keep current sentinel as first option
  if [ "$cmd" = "update-backend" ]; then
    local dom="${CURRENT_ARGS[0]:-}"
    if [ -n "$dom" ]; then
      local cur_img
      cur_img="$(get_backend_image "$dom" 2>/dev/null || true)"
      if [ -n "$cur_img" ]; then
        echo "__DEFAULT__|Keep current: $cur_img"
      else
        echo "__DEFAULT__|Keep current"
      fi
    fi
  fi
  local image_lines=""
  image_lines="$(_cli_prompt_cached_docker_images)"
  if [ -n "$image_lines" ]; then
    local ref img_id created digest_short digest
    while IFS='|' read -r ref img_id created digest; do
      [ -n "$ref" ] || continue
      if [[ "$ref" == "<none>:<none>" || "$ref" == *":<none>" ]]; then
        continue
      fi
      digest_short=""
      if [[ "$digest" == *@sha256:* ]]; then
        digest_short="${digest#*@sha256:}"
        digest_short="${digest_short:0:12}"
      elif [ -n "$img_id" ]; then
        digest_short="${img_id:0:12}"
      fi
      if [ -n "$digest_short" ]; then
        printf "%s|%s (@%s, created %s)\n" "$ref" "$ref" "$digest_short" "$created"
      else
        printf "%s|%s (created %s)\n" "$ref" "$ref" "$created"
      fi
    done <<<"$image_lines"
  fi
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_container_port() {
  local cmd="$1"
  # Suggest exposed ports from selected image; else common ports
  local img="" dom="" cur_port=""
  case "$cmd" in
  add-backend)
    img="${CURRENT_ARGS[1]:-}"
    ;;
  update-port)
    dom="${CURRENT_ARGS[0]:-}"
    cur_port="${CURRENT_ARGS[2]:-}"
    if [ -n "$cur_port" ]; then
      echo "__DEFAULT__|Keep current: $cur_port"
    fi
    if [ -n "$dom" ]; then
      img="$(get_backend_image "$dom" 2>/dev/null || true)"
    fi
    ;;
  update-backend)
    dom="${CURRENT_ARGS[0]:-}"
    img="${CURRENT_ARGS[1]:-}"
    if [ -z "$img" ] && [ -n "$dom" ]; then
      img="$(get_backend_image "$dom" 2>/dev/null || true)"
    fi
    if [ -n "$dom" ]; then
      cur_port="$(get_backend_port "$dom" 2>/dev/null || true)"
      if [ -n "$cur_port" ]; then
        echo "__DEFAULT__|Keep current: $cur_port"
      fi
    fi
    ;;
  esac
  if [ -n "$img" ] && command -v docker >/dev/null 2>&1; then
    # Extract ExposedPorts keys like "80/tcp" -> 80
    docker image inspect "$img" --format '{{json .Config.ExposedPorts}}' 2>/dev/null |
      tr ',' '\n' |
      sed -n 's/.*"\([0-9][0-9]*\)\/[a-zA-Z0-9]*".*/\1/p' |
      sort -un
  fi
  # Fallback suggestions
  echo -e "80\n443\n8000\n3000\n5000\n18180"
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_nginx_image() {
  local cmd="${1:-}"
  if [ "$cmd" = "start-nginx" ]; then
    echo "__DEFAULT__|Keep current: ${NGINX_IMAGE}"
    __arg_choices_image "$cmd"
    return 0
  fi
  echo "__LATEST_IF_MISSING__|Latest (pull if missing; current policy: ${NGINX_PULL_MODE:-if-missing})"
  echo "__LATEST_ALWAYS__|Latest (always pull newest)"
  echo "__PINNED_CURRENT__|Use current image: ${NGINX_IMAGE} (current)"
  echo "__MANUAL__|Enter manually..."
}

function __arg_choices_certbot_image() {
  echo "__LATEST_IF_MISSING__|Latest (pull if missing; current policy: ${CERTBOT_PULL_MODE:-if-missing})"
  echo "__LATEST_ALWAYS__|Latest (always pull newest)"
  echo "__PINNED_CURRENT__|Use current image: ${CERTBOT_IMAGE} (current)"
  echo "__MANUAL__|Enter manually..."
}
