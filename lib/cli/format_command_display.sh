# shellcheck shell=bash

FORMAT_COMMAND_DISPLAY_CACHE_KEYS=()
FORMAT_COMMAND_DISPLAY_CACHE_VALUES=()

function format_command_display() {
  local label="$1" desc="$2"
  local width="${COLUMNS:-80}" padding=6 max_width indent="    "
  local cache_key="${width}|${label}|${desc}"
  local cache_idx=0
  for ((cache_idx = 0; cache_idx < ${#FORMAT_COMMAND_DISPLAY_CACHE_KEYS[@]}; cache_idx++)); do
    if [ "${FORMAT_COMMAND_DISPLAY_CACHE_KEYS[$cache_idx]}" = "$cache_key" ]; then
      printf '%b' "${FORMAT_COMMAND_DISPLAY_CACHE_VALUES[$cache_idx]}"
      return 0
    fi
  done

  if [ -z "$desc" ]; then
    FORMAT_COMMAND_DISPLAY_CACHE_KEYS+=("$cache_key")
    FORMAT_COMMAND_DISPLAY_CACHE_VALUES+=("$label")
    printf '%s' "$label"
    return
  fi
  max_width=$((width - padding))
  if [ "$max_width" -lt 30 ]; then
    max_width=30
  fi
  local text="${label} — ${desc}"
  if command -v fold >/dev/null 2>&1; then
    text="$(printf '%s' "$text" | fold -s -w "$max_width")"
  fi
  local formatted="" first=true line
  while IFS= read -r line; do
    if $first; then
      formatted="$line"
      first=false
    else
      formatted="${formatted}\n${indent}${line}"
    fi
  done <<<"$text"
  FORMAT_COMMAND_DISPLAY_CACHE_KEYS+=("$cache_key")
  FORMAT_COMMAND_DISPLAY_CACHE_VALUES+=("$formatted")
  printf '%b' "$formatted"
}
