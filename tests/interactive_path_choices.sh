#!/usr/bin/env bash
# Scripted input globals are consumed by production prompt helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/helpers/path_choice_prompts.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/interactive-path-choices.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
export LC_ALL=C
BACKEND_PORTS_FILE="$TEST_WORK/backend_ports.csv"
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
expected_paths=('/(api|assets)' /api '/api|assets')
for path in "${expected_paths[@]}"; do
  is_valid_path_prefix "$path" || fail_test "Valid path rejected: $path"
  state_backend_ports_row_path example.com "$path" '' 38080 inherit inherit '' prefix 100 '' none - auto >>"$BACKEND_PORTS_FILE"
done
# The producer must still filter by both domain and listener.
state_backend_ports_row_path other.example.com /other '' 38080 inherit inherit '' >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_path example.com /other-port '' 38081 inherit inherit '' >>"$BACKEND_PORTS_FILE"
for path in '/a,b' '/a"b' "/a'b" '/a\b'; do
  if is_valid_path_prefix "$path"; then fail_test "Path validation unexpectedly accepted $path"; fi
done

CURRENT_ARGS=(example.com 38080)
choices="$(__arg_choices_path_prefix remove-path-option)"
choice_index=0
while IFS= read -r choice; do
  selected="" label=""
  cli_choice_line_to_value_label "$choice" selected label
  [ "$choice_index" -lt "${#expected_paths[@]}" ] || fail_test 'Choice producer leaked another domain or port'
  [ "$selected" = "${expected_paths[choice_index]}" ] || fail_test "Producer/parser changed path value: $selected"
  [ "$label" = "${expected_paths[choice_index]}" ] || fail_test "Producer/parser changed path label: $label"
  choice_index=$((choice_index + 1))
done <<<"$choices"
[ "$choice_index" -eq 3 ] || fail_test 'Choice producer omitted a path'

for command in update-path-option remove-path-option set-nginx-directive set-nginx-directive-raw remove-nginx-directive remove-all-nginx-directives list-nginx-directives; do
  for choice_index in 0 1 2; do
    collect_path_choice "$command" "$choice_index" >"$TEST_WORK/prompt-output" || fail_test "Prompt failed for $command"
    [ "$SELECTED_CMD" = "$command" ] || fail_test 'Collector changed command'
    case "$command" in
    update-path-option | remove-path-option) value_index=2; expected_count=3 ;;
    set-nginx-directive | set-nginx-directive-raw) value_index=3; expected_count=6 ;;
    remove-nginx-directive) value_index=3; expected_count=5 ;;
    *) value_index=3; expected_count=4 ;;
    esac
    [ "${#SELECTED_ARGS[@]}" -eq "$expected_count" ] || fail_test "Wrong argument count for $command"
    [ "${SELECTED_ARGS[value_index]}" = "${expected_paths[choice_index]}" ] || fail_test "Collector changed $command path"
    for label_index in 0 1 2; do
      [ "${PATH_CHOICE_LABELS[label_index]}" = "${expected_paths[label_index]}" ] || fail_test "Collector changed $command label"
    done
  done
done
printf '[PASS] path choices preserve literal pipes in labels and both picker collectors\n'
