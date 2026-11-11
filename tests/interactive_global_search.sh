#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/cli/common.sh
source "$ROOT_DIR/lib/cli/common.sh"
# shellcheck source=../lib/cli/format_command_display.sh
source "$ROOT_DIR/lib/cli/format_command_display.sh"
# shellcheck source=../lib/cli/command_alias.sh
source "$ROOT_DIR/lib/cli/command_alias.sh"
# shellcheck source=../lib/cli/command_description.sh
source "$ROOT_DIR/lib/cli/command_description.sh"
# shellcheck source=../lib/cli/command_descriptions.sh
source "$ROOT_DIR/lib/cli/command_descriptions.sh"
# shellcheck source=../lib/cli/interactive_picker_menu_data.sh
source "$ROOT_DIR/lib/cli/interactive_picker_menu_data.sh"
# shellcheck source=../lib/cli/render_interactive.sh
source "$ROOT_DIR/lib/cli/render_interactive.sh"
# shellcheck source=../lib/cli/choose_command_with_filter.sh
source "$ROOT_DIR/lib/cli/choose_command_with_filter.sh"

function require_valid_var_name() { [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
function clear() { :; }

function cli_read_keypress() {
  local __out_var="${1:-}"
  printf -v "$__out_var" '%s' ""
  return 0
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-global-search.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

function assert_flattened_command() {
  local wanted_command="$1"
  local wanted_category="$2"
  local __commands=()
  local __categories=()
  local idx

  interactive_flatten_picker_commands
  __commands=("${INTERACTIVE_PICKER_FLATTENED_COMMANDS[@]}")
  __categories=("${INTERACTIVE_PICKER_FLATTENED_CATEGORIES[@]}")
  for idx in "${!__commands[@]}"; do
    if [ "${__commands[$idx]}" = "$wanted_command" ] && [ "${__categories[$idx]}" = "$wanted_category" ]; then
      return 0
    fi
  done

  echo "[Error] Expected '${wanted_command}' to be flattened under '${wanted_category}'." >&2
  exit 1
}

assert_flattened_command "status" "Basic Ops"
assert_flattened_command "add-port" "Routing & Ports"
assert_flattened_command "add-cert" "Certificates"
assert_flattened_command "enable-backend-mtls" "Backend mTLS & Client Certs"

description_filter="mutual TLS"
description_choice=""
description_output_file="${tmp_dir}/description-search.out"
choose_global_command_with_filter description_choice description_filter "Search all commands:" >"$description_output_file"
if [ "$description_choice" != "enable-backend-mtls" ]; then
  echo "[Error] Description search should select enable-backend-mtls, got '${description_choice}'." >&2
  exit 1
fi
if ! grep -Fq "Backend mTLS & Client Certs :: Enable Backend mTLS" "$description_output_file"; then
  echo "[Error] Global search results should include category context in display text." >&2
  exit 1
fi

category_filter="bulk backend operations"
category_choice=""
category_output_file="${tmp_dir}/category-search.out"
choose_global_command_with_filter category_choice category_filter "Search all commands:" >"$category_output_file"
if [ "$category_choice" != "start-all-backends" ]; then
  echo "[Error] Category search should select start-all-backends, got '${category_choice}'." >&2
  exit 1
fi
if ! grep -Fq "Bulk Backend Operations :: Start All Backends" "$category_output_file"; then
  echo "[Error] Category search output should show bulk backend command context." >&2
  exit 1
fi

no_match_filter="definitely-no-command-matches-this-filter"
no_match_choice="kept"
no_match_output_file="${tmp_dir}/no-match-search.out"
no_match_error_file="${tmp_dir}/no-match-search.err"
no_match_probe_file="${tmp_dir}/no-match-search.probe"
set +e
(
  choose_global_command_with_filter no_match_choice no_match_filter "Search all commands:" >"$no_match_output_file"
  no_match_status=$?
  printf '%s\n%s\n%s\n' "$no_match_status" "$no_match_choice" "$no_match_filter" >"$no_match_probe_file"
) 2>"$no_match_error_file"
no_match_probe_status=$?
set -e
if [ "$no_match_probe_status" -ne 0 ] || [ ! -f "$no_match_probe_file" ]; then
  echo "[Error] A no-match global search crashed: $(cat "$no_match_error_file")" >&2
  exit 1
fi
no_match_status="$(sed -n '1p' "$no_match_probe_file")"
no_match_choice="$(sed -n '2p' "$no_match_probe_file")"
no_match_filter="$(sed -n '3p' "$no_match_probe_file")"
if [ "$no_match_status" -eq 0 ]; then
  echo "[Error] A no-match global search should select the Back row and return non-zero." >&2
  exit 1
fi
if grep -Fq "unbound variable" "$no_match_error_file"; then
  echo "[Error] A no-match global search hit a Bash 3 unbound-variable failure." >&2
  exit 1
fi
if [ -n "$no_match_choice" ]; then
  echo "[Error] A no-match global search should clear the selected command." >&2
  exit 1
fi
if [ "$no_match_filter" != "definitely-no-command-matches-this-filter" ]; then
  echo "[Error] A no-match global search should preserve the active filter." >&2
  exit 1
fi
if ! grep -Fq "No commands match the filter." "$no_match_output_file"; then
  echo "[Error] A no-match global search should explain that no commands matched." >&2
  exit 1
fi
if ! grep -Fq "> 1) Back" "$no_match_output_file"; then
  echo "[Error] A no-match global search should render Back as the only selectable row." >&2
  exit 1
fi

INTERACTIVE_PICKER_COMMANDS_DIAG+=("status")
duplicate_commands=()
duplicate_categories=()
interactive_flatten_picker_commands
duplicate_commands=("${INTERACTIVE_PICKER_FLATTENED_COMMANDS[@]}")
duplicate_categories=("${INTERACTIVE_PICKER_FLATTENED_CATEGORIES[@]}")
status_count=0
status_category=""
for idx in "${!duplicate_commands[@]}"; do
  if [ "${duplicate_commands[$idx]}" = "status" ]; then
    status_count=$((status_count + 1))
    status_category="${duplicate_categories[$idx]}"
  fi
done
if [ "$status_count" -ne 1 ]; then
  echo "[Error] Duplicate command flattening should keep status once, got ${status_count} entries." >&2
  exit 1
fi
if [ "$status_category" != "Basic Ops" ]; then
  echo "[Error] Duplicate command flattening should preserve the first category, got '${status_category}'." >&2
  exit 1
fi

echo "[tests] interactive_global_search.sh: PASS"
