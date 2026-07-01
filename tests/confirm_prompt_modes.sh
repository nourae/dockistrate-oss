#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/utils/prompts.sh
source "$ROOT_DIR/lib/utils/prompts.sh"

READ_QUEUE=()
READ_FAIL=0
INTERACTIVE=false

function read_with_editing() {
  local _prompt="${1:-}" __var="${2:-}" _default="${3:-}" value=""
  [ -n "$__var" ] || return 1
  if [ "${READ_FAIL}" -ne 0 ]; then
    return 1
  fi
  if [ "${#READ_QUEUE[@]}" -gt 0 ]; then
    value="${READ_QUEUE[0]}"
    READ_QUEUE=("${READ_QUEUE[@]:1}")
  fi
  printf -v "$__var" '%s' "$value"
}

if ! confirm_prompt "Question?" "yes_no"; then
  echo "[Error] yes_no should auto-confirm in non-interactive mode." >&2
  exit 1
fi

warn_output="$(confirm_prompt "Question?" "yes_no" "warn_yes" 2>&1)"
if ! grep -Fq "Non-interactive confirmation auto-approved" <<<"$warn_output"; then
  echo "[Error] yes_no warn_yes should print a compatibility warning." >&2
  echo "$warn_output" >&2
  exit 1
fi
if ! grep -Fq "Pass an explicit confirmation flag to make this explicit" <<<"$warn_output"; then
  echo "[Error] yes_no warn_yes should use the generic explicit-confirmation hint by default." >&2
  echo "$warn_output" >&2
  exit 1
fi
if grep -Fq "Pass --yes to make this explicit" <<<"$warn_output"; then
  echo "[Error] yes_no warn_yes should not hard-code --yes in the shared helper default." >&2
  echo "$warn_output" >&2
  exit 1
fi

custom_warn_output="$(confirm_prompt "Question?" "yes_no" "warn_yes" "--force" 2>&1)"
if ! grep -Fq "Pass --force to make this explicit" <<<"$custom_warn_output"; then
  echo "[Error] yes_no warn_yes should honor an explicit confirmation hint." >&2
  echo "$custom_warn_output" >&2
  exit 1
fi

if confirm_prompt "Question?" "yes_no" "require_yes" >/dev/null 2>&1; then
  echo "[Error] yes_no require_yes should fail in non-interactive mode." >&2
  exit 1
fi

if confirm_prompt "Type YES to proceed:" "strict_yes" >/dev/null 2>&1; then
  echo "[Error] strict_yes should fail in non-interactive mode." >&2
  exit 1
fi

INTERACTIVE=true
READ_QUEUE=("YES")
if ! confirm_prompt "Type YES to proceed:" "strict_yes"; then
  echo "[Error] strict_yes should accept exact YES." >&2
  exit 1
fi

READ_QUEUE=("yes")
set +e
reject_output="$(confirm_prompt "Type YES to proceed:" "strict_yes" 2>&1)"
reject_status=$?
set -e
if [ "$reject_status" -eq 0 ]; then
  echo "[Error] strict_yes should reject lowercase yes." >&2
  exit 1
fi
case "$reject_output" in
*"[Error] Confirmation rejected. Please type YES exactly to proceed."*) ;;
*)
  echo "[Error] strict_yes lowercase rejection should explain exact YES requirement." >&2
  echo "$reject_output" >&2
  exit 1
  ;;
esac

READ_FAIL=1
if confirm_prompt "Type YES to proceed:" "strict_yes" >/dev/null 2>&1; then
  echo "[Error] strict_yes should fail when read_with_editing fails." >&2
  exit 1
fi

echo "[tests] confirm_prompt_modes.sh: PASS"
