# shellcheck shell=bash

function normalize_yes_no_answer() {
  local raw="${1:-}" default_answer="${2:-}" normalized=""

  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  [ -n "$normalized" ] || normalized="$(printf '%s' "$default_answer" | tr '[:upper:]' '[:lower:]')"

  case "$normalized" in
  y | yes | on)
    printf '%s\n' "yes"
    return 0
    ;;
  n | no | off)
    printf '%s\n' "no"
    return 0
    ;;
  esac

  return 1
}

function read_yes_no_with_default() {
  local __var="${1:-}" question="${2:-}" default_answer="${3:-}" answer="" normalized=""
  if [[ ! "$__var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__var" >&2
    return 1
  fi

  while true; do
    read_with_editing "$question" answer
    if normalized="$(normalize_yes_no_answer "$answer" "$default_answer")"; then
      printf -v "$__var" '%s' "$normalized"
      return 0
    fi
    echo "[Error] Please answer yes or no." >&2
  done
}

# Prompt for confirmation for the given question.
# Arguments:
#   $1 - question/prompt text
#   $2 - mode (optional): "yes_no" or "strict_yes"; defaults to "yes_no"
#   $3 - non-interactive policy for yes_no (optional): auto_yes, warn_yes, or require_yes
# Modes:
#   yes_no: when INTERACTIVE=true, accepts yes/no input (default answer: "no");
#           when non-interactive, follows the selected policy.
#   strict_yes: when INTERACTIVE=true, requires the exact answer "YES";
#               when non-interactive, prints an error and returns 1.
function confirm_prompt() {
  local question="${1:-}" mode="${2:-yes_no}" noninteractive_policy="${3:-auto_yes}" ans=""

  case "$mode" in
  strict_yes)
    if [ "${INTERACTIVE:-false}" != true ]; then
      echo "[Error] Confirmation required. Re-run with -i/--interactive and type YES to proceed." >&2
      return 1
    fi
    if ! read_with_editing "$question" ans; then
      echo "[Error] Confirmation input failed. Re-run with -i/--interactive and type YES to proceed." >&2
      return 1
    fi
    if [ "$ans" = "YES" ]; then
      return 0
    fi
    echo "[Error] Confirmation rejected. Please type YES exactly to proceed." >&2
    return 1
    ;;
  yes_no)
    if [ "${INTERACTIVE:-false}" = true ]; then
      read_yes_no_with_default ans "$question" "no" || return 1
      [ "$ans" = "yes" ]
    else
      case "$noninteractive_policy" in
      auto_yes)
        return 0
        ;;
      warn_yes)
        echo "[Warn] Non-interactive confirmation auto-approved for compatibility. Pass --yes to make this explicit." >&2
        return 0
        ;;
      require_yes)
        echo "[Error] Confirmation required. Re-run with -i/--interactive or pass an explicit confirmation flag." >&2
        return 1
        ;;
      *)
        echo "[Error] Unknown non-interactive confirmation policy: $noninteractive_policy" >&2
        return 1
        ;;
      esac
    fi
    ;;
  *)
    echo "[Error] Unknown confirmation mode: $mode" >&2
    return 1
    ;;
  esac
}

# Read a value into a variable when INTERACTIVE is enabled, otherwise use the default.
function prompt_input() {
  local __var="$1" prompt="$2" default="${3:-}"
  local val="$default"
  if [[ ! "$__var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__var" >&2
    return 1
  fi
  if [ "$INTERACTIVE" = true ]; then
    if [ -n "$default" ]; then
      read_with_editing "$prompt [$default]: " val "$default"
      [ -z "$val" ] && val="$default"
    else
      read_with_editing "$prompt: " val
    fi
  fi
  printf -v "$__var" '%s' "$val"
}

# Require validation in non-interactive; in interactive, re-prompt until valid
function prompt_input_valid() {
  local __var="$1" prompt="$2" default="${3:-}" validator="$4"
  local val
  if [[ ! "$__var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__var" >&2
    return 1
  fi
  while true; do
    if [ -n "$default" ]; then
      read_with_editing "$prompt [$default]: " val "$default"
      [ -z "$val" ] && val="$default"
    else
      read_with_editing "$prompt: " val
    fi
    if "$validator" "$val"; then
      val="$(normalize_validated_value "$validator" "$val")"
      printf -v "$__var" '%s' "$val"
      return 0
    fi
    echo "[Error] Invalid value for $prompt. Please try again." >&2
  done
}

function ensure_valid_or_prompt() {
  local __var="$1" current_val="${2:-}" prompt="$3" default="${4:-}" validator="$5"
  if [[ ! "$__var" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "[Error] Invalid output variable name: $__var" >&2
    return 1
  fi
  if "$validator" "$current_val"; then
    current_val="$(normalize_validated_value "$validator" "$current_val")"
    printf -v "$__var" '%s' "$current_val"
    return 0
  fi
  if [ "$INTERACTIVE" = true ]; then
    # If an initial value was provided but invalid, surface the error immediately
    if [ -n "$current_val" ]; then
      echo "[Error] Invalid value for $prompt. Please try again." >&2
    fi
    prompt_input_valid "$__var" "$prompt" "$default" "$validator"
  else
    echo "[Error] Invalid $prompt: $current_val" >&2
    exit 1
  fi
}
