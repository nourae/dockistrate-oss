# shellcheck shell=bash

# Shared CLI parsing helpers for argument specs and interactive choice rows.
# Canonical format is CSV where each row is:
# - arg spec row:    name,default
# - choice row:      value,label

CLI_SPEC_NAMES=()
CLI_SPEC_DEFAULTS=()

function cli_read_keypress() {
  local __out_var="${1:-}" __key=""
  require_valid_var_name "$__out_var" || return 1
  if ! IFS= read -rsn1 __key; then
    printf -v "$__out_var" '%s' ""
    return 1
  fi
  printf -v "$__out_var" '%s' "$__key"
  return 0
}

function cli_print_prompt() {
  local prompt="${1:-}"
  printf '%s\n' "${prompt//\\n/$'\n'}"
}

function cli_parse_arg_spec() {
  local spec="${1:-}" pair="" name="" default=""
  local IFS=';'
  local pairs=()

  CLI_SPEC_NAMES=()
  CLI_SPEC_DEFAULTS=()
  [ -n "$spec" ] || return 0

  read -ra pairs <<<"$spec"
  for pair in "${pairs[@]}"; do
    [ -n "$pair" ] || continue

    if csv_parse_line "$pair" && [ "$CSV_FIELD_COUNT" -eq 2 ]; then
      name="${CSV_FIELDS[0]}"
      default="${CSV_FIELDS[1]}"
    elif [[ "$pair" == *'|'* ]]; then
      # Transitional fallback for legacy in-tree producers.
      name="${pair%%|*}"
      default="${pair#*|}"
    elif [[ "$pair" == *,* ]]; then
      # Fallback for malformed CSV rows without quotes.
      name="${pair%%,*}"
      default="${pair#*,}"
    else
      name="$pair"
      default=""
    fi

    CLI_SPEC_NAMES+=("$name")
    CLI_SPEC_DEFAULTS+=("$default")
  done
}

function cli_choice_line_to_value_label() {
  # Keep internal names distinct from caller output variable names.
  # With printf -v and set -u, name collisions can leave caller vars unset.
  local line="${1:-}" __parsed_value="" __parsed_label=""
  local __value_var="${2:-}" __label_var="${3:-}"

  __parsed_value="$line"
  __parsed_label="$line"

  if csv_parse_line "$line" && [ "$CSV_FIELD_COUNT" -eq 2 ]; then
    __parsed_value="${CSV_FIELDS[0]}"
    __parsed_label="${CSV_FIELDS[1]}"
  elif [[ "$line" == *'|'* ]]; then
    # Transitional fallback for legacy in-tree producers.
    __parsed_value="${line%%|*}"
    __parsed_label="${line#*|}"
  fi

  [ -n "$__value_var" ] && printf -v "$__value_var" '%s' "$__parsed_value"
  [ -n "$__label_var" ] && printf -v "$__label_var" '%s' "$__parsed_label"
}
