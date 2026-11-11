#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-loader-order.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
export LC_ALL=C

LOADERS=(
  access_log backends backups capture certs clean_uninstall cli config dependencies
  global_settings headers http_version loader logging mtls nginx nginx_directives
  permissions ports security_rules tls tokens utils
)
MODULE_FILES=('10-first.sh' '15 space.sh' '16*glob?.sh' $'17 line\nbreak.sh' '90-last.sh')

function fail() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

function prepare_checkout() {
  local checkout="$1" name module
  mkdir -p "$checkout/lib"
  cp "$ROOT_DIR/lib/runtime_paths.sh" "$checkout/lib/runtime_paths.sh"
  for name in "${LOADERS[@]}"; do
    cp "$ROOT_DIR/lib/$name.sh" "$checkout/lib/$name.sh"
    mkdir "$checkout/lib/$name"
    # Record the exact source path so ordering, exclusions and pathname bytes
    # are checked independently of the loader's basename implementation.
    printf '%s\n' 'printf "%s\0" "${BASH_SOURCE[0]}" >>"$LOAD_RECORD"' \
      'function fixture_common_ready() { :; }' >"$checkout/lib/$name/common.sh"
    for module in "${MODULE_FILES[@]}"; do
      printf '%s\n' 'fixture_common_ready' \
        'printf "%s\0" "${BASH_SOURCE[0]}" >>"$LOAD_RECORD"' \
        'function fixture_command_ready() { :; }' >"$checkout/lib/$name/$module"
    done
  done
  printf '%s\n' 'printf "%s\0" "${BASH_SOURCE[0]}" >>"$LOAD_RECORD"' \
    >"$checkout/lib/config/schema_version.sh"
  printf '%s\n' 'fixture_common_ready' \
    'printf "%s\0" "${BASH_SOURCE[0]}" >>"$LOAD_RECORD"' \
    'function _set_command_description() { printf "%s" loaded; }' \
    >"$checkout/lib/cli/_set_command_description.sh"
}

function check_loader() (
  local checkout="$1" name="$2" label="$3" preloaded="${4:-false}" module
  local LOAD_RECORD="$FIXTURE/actual" expected="$FIXTURE/expected"
  local module_dir
  # Loaders have always resolved their directory through cd/pwd. Honor the
  # native logical/physical directory behavior without assuming mktemp or an
  # alias uses the same spelling; every ordered source pathname stays exact.
  module_dir="$(cd "$checkout/lib/$name" && pwd)"
  : >"$LOAD_RECORD"
  : >"$expected"
  if [ "$name" = config ]; then
    printf '%s\0' "$module_dir/schema_version.sh" >>"$expected"
  fi
  printf '%s\0' "$module_dir/common.sh" >>"$expected"
  if [ "$name" = cli ]; then
    if [ "$preloaded" = true ]; then
      function _set_command_description() { printf '%s' preloaded; }
    else
      printf '%s\0' "$module_dir/_set_command_description.sh" >>"$expected"
    fi
  fi
  for module in "${MODULE_FILES[@]}"; do
    printf '%s\0' "$module_dir/$module" >>"$expected"
  done

  # Source the real loader directly; fixture modules intentionally have no
  # runtime state, Docker access, or dependence on other feature modules.
  # shellcheck disable=SC1090
  source "$checkout/lib/$name.sh"
  cmp -s "$expected" "$LOAD_RECORD" || fail "$label/$name source order or exact source paths differ"
  declare -F fixture_command_ready >/dev/null || fail "$label/$name did not expose its commands"
  if [ "$name" = config ] || [ "$name" = utils ]; then
    declare -F __dockistrate_runtime_paths_loaded >/dev/null || fail "$label/$name did not load its runtime path dependency"
  fi
  if [ "$name" = cli ]; then
    if [ "$preloaded" = true ]; then
      [ "$(_set_command_description)" = preloaded ] || fail 'CLI loader replaced an existing description helper'
    else
      [ "$(_set_command_description)" = loaded ] || fail 'CLI loader did not load its description helper'
    fi
  fi
  printf '[tests] module-loader PASS: %s/%s\n' "$label" "$name"
)

plain="$FIXTURE/plain"
odd="$FIXTURE/"$'-checkout space [*]\n'
prepare_checkout "$plain"
prepare_checkout "$odd"
# Enter through an alias whose path also needs quoting. The existing loader
# directory-resolution behavior must still expose the same ordered modules.
alias_path="$FIXTURE/alias space"
ln -s "$odd" "$alias_path"
for loader in "${LOADERS[@]}"; do
  check_loader "$plain" "$loader" plain
  check_loader "$odd" "$loader" odd
  check_loader "$alias_path" "$loader" odd_alias
done
check_loader "$alias_path" cli preloaded_cli true
printf 'Module loader ordering and direct sourcing checks passed (70 cases).\n'
