#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/prompt_args_handlers_postprocess.sh
source "$ROOT_DIR/lib/cli/prompt_args_handlers_postprocess.sh"

function assert_collected_args_empty() {
  local label="${1:-postprocess}"
  if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 0 ]; then
    echo "[Error] ${label} should produce an empty argument list." >&2
    exit 1
  fi
}

for command in stop-all-backends remove-all-backends renew-certs stop-capture remove-all-headers; do
  PROMPT_ARGS_COLLECTED=()
  prompt_args_postprocess "$command"
  assert_collected_args_empty "$command with no collected answers"
done

PROMPT_ARGS_COLLECTED=("")
prompt_args_postprocess set-nginx-docker-opts
if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 1 ] || [ -n "${PROMPT_ARGS_COLLECTED[0]}" ]; then
  echo '[Error] Explicit empty option values must survive postprocessing.' >&2
  exit 1
fi

PROMPT_ARGS_COLLECTED=("__ALL__")
prompt_args_postprocess "remove-all-path-options"
assert_collected_args_empty "remove-all-path-options all-domains selection"

PROMPT_ARGS_COLLECTED=("__DEFAULT__")
prompt_args_postprocess "fix-permissions"
assert_collected_args_empty "fix-permissions default selection"

# Permission repair exposes its alternate-directory flow through the same
# mode picker while retaining default and Darwin choices at their old indices.
# shellcheck source=../lib/cli/arg_choices_security.sh
source "$ROOT_DIR/lib/cli/arg_choices_security.sh"
permissions_choices="$(__arg_choices_mode fix-permissions)"
case "$permissions_choices" in
__DEFAULT__'|'*$'\n'--certbot-darwin-user'|'*$'\n'__MANUAL__'|'*) ;;
*)
  echo '[Error] Permission repair mode choices lost default, Darwin, or manual target flow.' >&2
  exit 1
  ;;
esac
for selected in '/operator/alternate keys' '--certbot-darwin-user'; do
  PROMPT_ARGS_COLLECTED=("$selected")
  prompt_args_postprocess fix-permissions
  if [ "${#PROMPT_ARGS_COLLECTED[@]}" -ne 1 ] || [ "${PROMPT_ARGS_COLLECTED[0]:-}" != "$selected" ]; then
    echo '[Error] Permission repair postprocess changed an explicit mode/target.' >&2
    exit 1
  fi
done

PROMPT_ARGS_COLLECTED=("" "no")
prompt_args_postprocess "upgrade-preflight"
assert_collected_args_empty "upgrade-preflight default selection"

NGINX_IMAGE="nginx:latest"
NGINX_DOCKER_OPTS=""
PROMPT_ARGS_COLLECTED=("__DEFAULT__" "")
prompt_args_postprocess "start-nginx"
assert_collected_args_empty "start-nginx default selection"

echo "[tests] prompt_args_postprocess_empty_arrays.sh: PASS"
