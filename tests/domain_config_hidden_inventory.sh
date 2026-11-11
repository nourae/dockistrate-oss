#!/usr/bin/env bash
# Fixture paths are consumed by sourced domain configuration helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-hidden-inventory.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"
_domain_config_bind_config "$STATE_DIR/config"
draft="$STATE_DIR/domains/example.com/config"
applied="$STATE_DIR/domains/example.com/runtime/applied"
mkdir -p "$draft"
printf 'schema_version,role,target\n5,certificate-only,\n' >"$draft/domain.csv"
_domain_config_copy_inputs "$draft" "$applied"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function expect_invalid_inventory() {
  if domain_config_validate_source example.com "$draft" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Hidden entry passed source validation.'; fi
  if domain_config_canonicalize "$draft" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Hidden entry was ignored by canonicalization.'; fi
  if _domain_config_guard_pending example.com >"$TEST_WORK/rejected" 2>&1; then fail_test 'Hidden entry bypassed the CLI pending-edit guard.'; fi
  [ "${DOMAIN_CONFIG_PENDING_DOMAIN:-}" = example.com ] || fail_test 'Pending guard did not identify the affected domain.'
}

domain_config_validate_source example.com "$draft"
_domain_config_guard_pending example.com
baseline="$(_domain_config_input_fingerprint "$draft")"
# Preserve flat-file fingerprint bytes for old source journals without hidden
# entries; adding visibility must not introduce a new wire representation.
expected="$(printf 'domain.csv\n'; cksum <"$draft/domain.csv")"
[ "$baseline" = "$expected" ] || fail_test 'Existing flat fingerprint format changed.'

for name in .notes ..notes; do
  printf 'unfinished operator notes\n' >"$draft/$name"
  expect_invalid_inventory
  fingerprint="$(_domain_config_input_fingerprint "$draft")"
  [ "$fingerprint" != "$baseline" ] || fail_test 'Fingerprint omitted a hidden regular file.'
  _domain_config_copy_inputs "$draft" "$TEST_WORK/copied-$name"
  cmp -s "$draft/$name" "$TEST_WORK/copied-$name/$name" || fail_test 'Raw input capture lost a hidden regular file.'
  printf 'new editor bytes\n' >>"$draft/$name"
  [ "$fingerprint" != "$(_domain_config_input_fingerprint "$draft")" ] || fail_test 'Fingerprint ignored a concurrent hidden-file edit.'
  rm "$draft/$name"
done

for name in .editor ..editor; do
  mkdir "$draft/$name"
  printf 'nested draft\n' >"$draft/$name/note"
  expect_invalid_inventory
  if _domain_config_dir_guard "$draft" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Flat directory guard accepted a hidden subdirectory.'; fi
  if _domain_config_input_fingerprint "$draft" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Flat fingerprint traversed a hidden subdirectory.'; fi
  if _domain_config_copy_inputs "$draft" "$TEST_WORK/rejected-copy" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Flat copy traversed a hidden subdirectory.'; fi
  rm -rf "$draft/$name"
done

printf 'outside bytes\n' >"$TEST_WORK/outside"
ln -s "$TEST_WORK/outside" "$draft/.link"
expect_invalid_inventory
if _domain_config_dir_guard "$draft" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Hidden symlink passed the flat guard.'; fi
if _domain_config_copy_inputs "$draft" "$TEST_WORK/rejected-copy" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Flat capture followed a hidden symlink.'; fi
rm "$draft/.link"
_domain_config_guard_pending example.com
[ "$baseline" = "$(_domain_config_input_fingerprint "$draft")" ] || fail_test 'Rejected entries changed existing CSV data.'

# Explicit historical conversion must reject unknown hidden inputs before
# publication rather than discard them while rebuilding recognized CSV files.
for version in 2 3; do
  legacy="$TEST_WORK/legacy-$version"
  mkdir "$legacy"
  if [ "$version" = 2 ]; then
    printf 'key,value\nschema_version,2\nrole,certificate-only\n' >"$legacy/domain.csv"
  else
    printf 'schema_version,role,target\n3,certificate-only,\n' >"$legacy/domain.csv"
  fi
  printf 'legacy editor notes\n' >"$legacy/.notes"
  before="$(_domain_config_input_fingerprint "$legacy")"
  if _domain_csv_convert_directory "$version" "$legacy" "$TEST_WORK/converted-$version" >"$TEST_WORK/rejected" 2>&1; then
    fail_test "Schema-$version conversion discarded hidden inputs."
  fi
  grep -q 'Unknown domain configuration file: .notes' "$TEST_WORK/rejected" || fail_test 'Historical conversion failed before inspecting the hidden entry.'
  [ "$before" = "$(_domain_config_input_fingerprint "$legacy")" ] || fail_test 'Refused conversion changed legacy source bytes.'
done
printf '[tests] domain_config_hidden_inventory.sh: PASS\n'
