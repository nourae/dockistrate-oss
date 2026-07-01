#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/csv.sh
source "$ROOT_DIR/lib/utils/csv.sh"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/is_back_input.sh
source "$ROOT_DIR/lib/cli/is_back_input.sh"
# shellcheck source=../lib/cli/collect_add_backend_interactive.sh
source "$ROOT_DIR/lib/cli/collect_add_backend_interactive.sh"

CHOICE_QUEUE=()
READ_QUEUE=()
READ_PROMPTS=()
LAST_PROMPT=""
LAST_OPTIONS=()

function fail() {
  echo "[Error] $*" >&2
  exit 1
}

function choose_option() {
  local __out_var="$1" prompt="$2"
  shift 2
  LAST_PROMPT="$prompt"
  LAST_OPTIONS=("$@")
  if [ "${#CHOICE_QUEUE[@]}" -eq 0 ]; then
    fail "choice queue exhausted"
  fi
  printf -v "$__out_var" '%s' "${CHOICE_QUEUE[0]}"
  CHOICE_QUEUE=("${CHOICE_QUEUE[@]:1}")
  return 0
}

function read_with_editing() {
  local prompt="$1" __out_var="$2"
  READ_PROMPTS+=("$prompt")
  if [ "${#READ_QUEUE[@]}" -eq 0 ]; then
    printf -v "$__out_var" '%s' "${3:-}"
    return 0
  fi
  printf -v "$__out_var" '%s' "${READ_QUEUE[0]}"
  READ_QUEUE=("${READ_QUEUE[@]:1}")
  return 0
}

opts=$'__DEFAULT__|Use default: 443\n80|80\n__MANUAL__|Enter manually...'
choice=""
CHOICE_QUEUE=(0)
READ_QUEUE=()
READ_PROMPTS=()
_collect_add_backend_choose_from_lines choice "Listen port" "$opts" "443" "Listen port" || fail "default listen choice failed"
[ "$choice" = "443" ] || fail "default choice should resolve to 443, got '$choice'"
[ "${#READ_PROMPTS[@]}" -eq 0 ] || fail "default choice should not prompt for text input"
case " ${LAST_OPTIONS[*]} " in
*" Use default: 443 "* | *"Use default: 443"*) ;;
*) fail "listen picker should display the default port choice" ;;
esac

choice=""
CHOICE_QUEUE=(2)
READ_QUEUE=(9443)
READ_PROMPTS=()
_collect_add_backend_choose_from_lines choice "Redirect target port" "$opts" "443" "Redirect target port" || fail "manual redirect choice failed"
[ "$choice" = "9443" ] || fail "manual choice should resolve to custom port 9443, got '$choice'"
[ "${#READ_PROMPTS[@]}" -eq 1 ] || fail "manual choice should prompt exactly once"
[ "${READ_PROMPTS[0]}" = "Redirect target port: " ] || fail "manual prompt should name the redirect target port"

choice="unchanged"
CHOICE_QUEUE=(3)
READ_QUEUE=()
READ_PROMPTS=()
if _collect_add_backend_choose_from_lines choice "Listen port" "$opts" "443" "Listen port"; then
  fail "Back choice should return nonzero"
fi
[ "$choice" = "unchanged" ] || fail "Back choice should not mutate the output value"

echo "add-backend port picker helper checks passed."
