# shellcheck shell=bash

function describe_image_with_local_state() {
  local image="$1" pull_mode="$2" label="$3" container="${4:-}"
  require_valid_image_ref "$image" "$label" || return 1
  local mode_note=""
  mode_note="$(image_pull_policy_note "$image" "$pull_mode")"
  local local_note="local: missing" running_img="" best_tag="" digest_short="" created="" identity_note=""
  if [ -n "$container" ] && command -v docker >/dev/null 2>&1; then
    running_img="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
  fi
  if command -v docker >/dev/null 2>&1; then
    local tags digest id inspect=""
    inspect="$(docker image inspect "$image" --format '{{join .RepoTags ","}}|{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}|{{.Id}}|{{.Created}}' 2>/dev/null || true)"
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
        identity_note="registry digest sha256:${digest_short}"
      elif [ -n "$id" ]; then
        digest_short="${id#sha256:}"
        digest_short="${digest_short:0:12}"
        identity_note="image ID sha256:${digest_short}"
      fi
      local_note="local: ${best_tag:-$image}"
      if [ -n "$digest_short" ]; then
        local_note+=" (${identity_note})"
      fi
      if [ -n "$created" ]; then
        local_note+=" (created ${created%%T*})"
      fi
    fi
  fi
  if [ -n "$running_img" ] && [ "$running_img" != "$image" ]; then
    local_note+="; running reference: ${running_img}"
  fi
  # Local aliases and image IDs must not replace or masquerade as the configured pin.
  echo "${label} image: ${image} [${mode_note}; ${local_note}]"
}
