#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.image-reporting.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
TRACE="$TMP_ROOT/docker.calls"
OUTPUT="$TMP_ROOT/output"
DIGEST="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
PIN="nginx:1.31.7@${DIGEST}"
MOCK_IMAGE="" MOCK_RUNNING="" MOCK_PULL_STATUS=0
SKIP_DOCKER_CHECKS=false

# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/config/image_uses_latest_tag.sh
source "$ROOT_DIR/lib/config/image_uses_latest_tag.sh"
# shellcheck source=../lib/config/normalize_image_with_latest.sh
source "$ROOT_DIR/lib/config/normalize_image_with_latest.sh"
# shellcheck source=../lib/config/pull_image_if_autopull.sh
source "$ROOT_DIR/lib/config/pull_image_if_autopull.sh"
# shellcheck source=../lib/nginx/describe_image_with_local_state.sh
source "$ROOT_DIR/lib/nginx/describe_image_with_local_state.sh"
# shellcheck source=../lib/global_settings/set_nginx_image.sh
source "$ROOT_DIR/lib/global_settings/set_nginx_image.sh"
# shellcheck source=../lib/global_settings/set_certbot_image.sh
source "$ROOT_DIR/lib/global_settings/set_certbot_image.sh"

function fail_test() { printf '[Error] %s\n' "$1" >&2; exit 1; }
function contains() { grep -Fq -- "$1" "$OUTPUT" || fail_test "Missing output: $1"; }
function excludes() { if grep -Fq -- "$1" "$OUTPUT"; then fail_test "Unexpected output: $1"; fi; }
function docker() {
  printf '%s\n' "$*" >>"$TRACE"
  case "${1:-}" in
  image)
    # Docker's Go template parser rejects literal backslash-escaped quotes here.
    [[ "${5:-}" != *'\"'* ]] || return 1
    [ -n "$MOCK_IMAGE" ] || return 1
    printf '%s\n' "$MOCK_IMAGE"
    ;;
  inspect) [ -n "$MOCK_RUNNING" ] || return 1; printf '%s\n' "$MOCK_RUNNING" ;;
  pull) return "$MOCK_PULL_STATUS" ;;
  *) return 1 ;;
  esac
}

# A local alias may describe the cache but must not replace the selected pin.
MOCK_IMAGE="unrelated:alias,nginx:latest|nginx@${DIGEST}|sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|2026-10-14T00:00:00Z"
describe_image_with_local_state "$PIN" if-missing Nginx >"$OUTPUT"
contains "Nginx image: $PIN [digest-pinned; explicit pull skipped;"
contains 'local: unrelated:alias'
contains 'registry digest sha256:aaaaaaaaaaaa'
excludes 'Nginx image: unrelated:alias'

# A cached tag does not become pinned merely because Docker reports a digest.
describe_image_with_local_state nginx:1.31.7 always Nginx >"$OUTPUT"
contains 'Nginx image: nginx:1.31.7 [mutable tag; explicit pull skipped;'
excludes 'digest-pinned'
excludes 'Nginx image: nginx:1.31.7@sha256:'

# An image ID is not a registry manifest digest; keep those identities distinct.
MOCK_IMAGE='nginx:local||sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|2026-10-14T00:00:00Z'
describe_image_with_local_state nginx:local never Nginx >"$OUTPUT"
contains 'image ID sha256:bbbbbbbbbbbb'
excludes 'registry digest'
excludes 'nginx:local@sha256:'

# Missing configured images and a still-running older reference remain distinct.
MOCK_IMAGE=''
MOCK_RUNNING='nginx:old'
describe_image_with_local_state "$PIN" never Nginx nginx-proxy >"$OUTPUT"
contains "Nginx image: $PIN [digest-pinned;"
contains 'local: missing; running reference: nginx:old'
excludes 'local: nginx:old'

# Digest references stay pinned even when the optional descriptive tag is latest.
describe_image_with_local_state "nginx:latest@${DIGEST}" always Nginx >"$OUTPUT"
contains '[digest-pinned; explicit pull skipped;'
describe_image_with_local_state "nginx@${DIGEST}" always Nginx >"$OUTPUT"
contains '[digest-pinned; explicit pull skipped;'

# Preserve actual pull behavior while correcting its description. An empty cache
# does not force an explicit pull for version tags, custom tags, or digests.
for image in "$PIN" "nginx@${DIGEST}" "nginx:latest@${DIGEST}" nginx:1.31.7 registry.example:5000/proxy:custom nginx:latest; do
  for mode in always if-missing never; do
    NGINX_IMAGE="$image" NGINX_PULL_MODE="$mode"
    : >"$TRACE"
    pull_image_if_autopull "$image" Nginx >"$OUTPUT" 2>&1
    if [ "$image" = nginx:latest ] && [ "$mode" != never ]; then
      [ "$(cat "$TRACE")" = 'pull nginx:latest' ] || fail_test "Latest policy changed: $mode"
      contains 'Pulled Nginx image: nginx:latest'
    else
      [ ! -s "$TRACE" ] || fail_test "Unexpected explicit Docker call for $image / $mode"
      case "$image" in
      *@*) contains 'digest-pinned' ;;
      nginx:latest) contains 'Docker may fetch it if missing locally' ;;
      *) contains 'mutable tag'; excludes 'digest-pinned' ;;
      esac
    fi
  done
done

MOCK_PULL_STATUS=1
NGINX_IMAGE=nginx:latest NGINX_PULL_MODE=always
pull_image_if_autopull "$NGINX_IMAGE" Nginx >"$OUTPUT" 2>&1
contains 'Unable to pull Nginx image nginx:latest; using local copy if available.'

# Exercise the shared CLI/interactive setters with persistence isolated from the
# host. Invalid references must still reject before saving or changing selection.
GLOBAL_SETTINGS_USAGE_PREFIX='[Usage]' GLOBAL_SETTINGS_ERROR_PREFIX='[Error]' GLOBAL_SETTINGS_INFO_PREFIX='[Info]'
GLOBAL_SETTINGS_FILE="$TMP_ROOT/global_settings.csv"
SKIP_DOCKER_CHECKS=true
function normalize_nginx_image() { normalize_image_with_latest "$1"; }
function _config_begin_return_transaction_if_needed() { printf -v "$1" '%s' false; }
function _config_end_transaction_if_started() { :; }
function save_config() { printf '%s\n' "${NGINX_IMAGE:-}" "${CERTBOT_IMAGE:-}" >"$GLOBAL_SETTINGS_FILE"; }
for setter in set_nginx_image set_certbot_image; do
  "$setter" "$PIN" if-missing >"$OUTPUT"
  contains 'digest-pinned; explicit pull skipped'
  "$setter" registry.example:5000/custom:stable never >"$OUTPUT"
  contains 'mutable tag; explicit pull skipped'
  excludes 'digest-pinned'
  cp "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/before"
  if "$setter" --privileged always >"$OUTPUT" 2>&1; then fail_test 'Option-shaped image accepted'; fi
  cmp -s "$GLOBAL_SETTINGS_FILE" "$TMP_ROOT/before" || fail_test 'Invalid image changed saved selection'
done

echo 'Image reference reporting and pull compatibility checks passed.'
