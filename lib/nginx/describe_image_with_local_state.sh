# shellcheck shell=bash

function describe_image_with_local_state() {
  local image="$1" pull_mode="$2" label="$3" container="${4:-}"
  local mode_note=""
  if image_uses_latest_tag "$image"; then
    mode_note="mode=${pull_mode:-if-missing}"
  else
    mode_note="pinned"
  fi
  local local_note="local: missing" running_img="" best_tag="" digest_short="" created=""
  if [ -n "$container" ] && command -v docker >/dev/null 2>&1; then
    running_img="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
  fi
  if command -v docker >/dev/null 2>&1; then
    local tags digest id inspect=""
    inspect="$(docker image inspect "$image" --format '{{join .RepoTags \",\"}}|{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}|{{.Id}}|{{.Created}}' 2>/dev/null || true)"
    if [ -z "$inspect" ] && [ -n "$container" ]; then
      inspect="$(docker inspect -f '{{join .RepoTags \",\"}}|{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}|{{.Image}}|{{.Created}}' "$container" 2>/dev/null || true)"
    fi
    if [ -n "$inspect" ]; then
      tags="${inspect%%|*}"
      digest="${inspect#*|}"
      digest="${digest%%|*}"
      id="${inspect#*|}"
      id="${id#*|}"
      id="${id%%|*}"
      created="${inspect##*|}"
      best_tag=""
      if [ -n "$tags" ] && [ "$tags" != "<none>:<none>" ]; then
        IFS=',' read -r -a _tags_arr <<<"$tags"
        local t
        for t in "${_tags_arr[@]}"; do
          if [[ "$t" != *":latest" ]]; then
            best_tag="$t"
            break
          fi
        done
        [ -n "$best_tag" ] || best_tag="${_tags_arr[0]}"
      fi
      if [ -n "$digest" ] && [[ "$digest" == *@sha256:* ]]; then
        digest_short="${digest#*@sha256:}"
        digest_short="${digest_short:0:12}"
      elif [ -n "$id" ]; then
        digest_short="${id#sha256:}"
        digest_short="${digest_short:0:12}"
      fi
      local_note="local: ${best_tag:-$image}"
      if [ -n "$digest_short" ]; then
        local_note+=" (@${digest_short})"
      fi
      if [ -n "$created" ]; then
        local_note+=" (created ${created%%T*})"
      fi
    fi
  fi
  if [ "$local_note" = "local: missing" ] && [ -n "$running_img" ]; then
    local_note="running: ${running_img}"
  fi
  local resolved="$image"
  if [ -n "$best_tag" ]; then
    resolved="$best_tag"
    if [ -n "$digest_short" ]; then
      resolved+=" (@${digest_short})"
    fi
  elif [ -n "$digest_short" ] && [[ "$image" == *@sha256:* ]]; then
    resolved="${image%@sha256:*}@sha256:${digest_short}"
  elif [ -n "$digest_short" ]; then
    resolved="${image}@sha256:${digest_short}"
  fi
  echo "${label} image: ${resolved} [${mode_note}; ${local_note}]"
}
