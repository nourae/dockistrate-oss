#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=lib/backends/identity.sh
source "$ROOT_DIR/lib/backends/identity.sh"
# shellcheck source=tests/lib/backend_identity_fixture.sh
source "$ROOT_DIR/tests/lib/backend_identity_fixture.sh"
# shellcheck source=lib/backends/runtime_rollback.sh
source "$ROOT_DIR/lib/backends/runtime_rollback.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backend_cleanup_identity.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
CONTAINER_ID="$(printf '%064d' 2)"
TOKEN=0123456789abcdef0123456789abcdef
TRACE="$TMP_ROOT/docker.log"
STATE_DIR="$TMP_ROOT/state"
mkdir -p "$STATE_DIR"
backend_fixture_seed_labels "$TMP_ROOT/labels" "$TOKEN" example.com "$STATE_DIR"

function fail() { echo "[Error] $CASE: $*" >&2; exit 1; }
function docker() {
  printf '%s\n' "$*" >>"$TRACE"
  case "${1:-}" in
  ps)
    case "$*" in
    *"label=com.dockistrate.backend-launch=$TOKEN"*)
      case "$CASE" in
      list_failure) return 1 ;;
      invalid_id) printf 'abc123\n' ;;
      *) printf '%s\n' "$CONTAINER_ID" ;;
      esac
      ;;
    *"id=$CONTAINER_ID"*)
      case "$CASE" in
      inspect_gone|remove_gone) : ;;
      probe_failure) return 1 ;;
      *) printf '%s\n' "$CONTAINER_ID" ;;
      esac
      ;;
    *) return 1 ;;
    esac
    ;;
  inspect)
    [ "${@: -1}" = "$CONTAINER_ID" ] || return 1
    case "$CASE" in
    inspect_present|inspect_gone|probe_failure) return 1 ;;
    label_mismatch) printf 'unverified\n' ;;
    id_mismatch) printf 'verified\n%064d\nrunning\nnginx:alpine\nsha256:abc\ndockistrate-net|172.30.0.2\n' 3 ;;
    *) backend_fixture_snapshot "$3" "$CONTAINER_ID" running "$TMP_ROOT/labels" ;;
    esac
    ;;
  rm)
    [ "$*" = "rm -f -v $CONTAINER_ID" ] || return 1
    case "$CASE" in remove_present|remove_gone) return 1 ;; esac
    ;;
  *) return 1 ;;
  esac
}

# Keep Docker external: Bash 3 handles ERR inheritance differently for an
# external command failing inside a command substitution than for a function.
BACKEND_IDENTITY_FIXTURE_FILE="$ROOT_DIR/tests/lib/backend_identity_fixture.sh"
export BACKEND_IDENTITY_FIXTURE_FILE TOKEN CONTAINER_ID TRACE TMP_ROOT STATE_DIR CASE
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'source "$BACKEND_IDENTITY_FIXTURE_FILE"' >"$TMP_ROOT/docker"
declare -f docker >>"$TMP_ROOT/docker"
printf '\ndocker "$@"\n' >>"$TMP_ROOT/docker"
chmod +x "$TMP_ROOT/docker"
unset -f docker
PATH="$TMP_ROOT:$PATH"
export PATH
ERR_TRACE="$TMP_ROOT/err-trap.log"
trap 'printf "unexpected ERR trap\n" >>"$ERR_TRACE"' ERR

for CASE in success list_failure invalid_id label_mismatch id_mismatch inspect_present inspect_gone probe_failure remove_present remove_gone invalid_token; do
  : >"$TRACE"
  : >"$ERR_TRACE"
  selected_token="$TOKEN"
  [ "$CASE" != invalid_token ] || selected_token=invalid
  if _backend_launch_cleanup "$selected_token" example.com >"$TMP_ROOT/output" 2>&1; then status=0; else status=$?; fi
  case "$CASE" in
  success|inspect_gone|remove_gone) [ "$status" -eq 0 ] || fail 'confirmed cleanup or disappearance reported failure' ;;
  *) [ "$status" -ne 0 ] || fail 'unverified cleanup incorrectly reported success' ;;
  esac
  case "$CASE" in
  success|remove_present|remove_gone)
    grep -Fxq "rm -f -v $CONTAINER_ID" "$TRACE" || fail 'cleanup did not target the full immutable ID'
    ;;
  *) if grep -q '^rm ' "$TRACE"; then fail 'cleanup removed a container without verified ownership'; fi ;;
  esac
  if [ "$CASE" = invalid_token ] && [ -s "$TRACE" ]; then fail 'invalid launch token reached Docker'; fi
  [ ! -s "$ERR_TRACE" ] || fail 'handled Docker failure invoked the inherited ERR trap'
  printf '[PASS] cleanup_identity_%s\n' "$CASE"
done
trap - ERR

CASE=launch_token
previous_token=''
for attempt in 1 2 3; do
  generated_token="$(_backend_launch_new_token)"
  [ "${#generated_token}" -eq 32 ] || fail 'launch token has unexpected length'
  case "$generated_token" in *[!0-9a-f]*) fail 'launch token is not lowercase hexadecimal' ;; esac
  [ "$generated_token" != "$previous_token" ] || fail 'separate launches reused a token'
  previous_token="$generated_token"
done
printf '[PASS] launch_token\n'
