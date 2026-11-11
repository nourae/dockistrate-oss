#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/domain_config.sh"
source "$ROOT_DIR/tests/helpers/domain_csv.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-mtls-restore-paths.XXXXXXXX")"
TEST_COMPLETE=false
test_status=0
trap 'test_status=$?; rm -rf "$TEST_WORK"; if [ "$TEST_COMPLETE" != true ] && [ "$test_status" -eq 0 ]; then test_status=1; fi; exit "$test_status"' EXIT
prepared="$TEST_WORK/prepared"
domain="$prepared/domains/portable.example.com"
old_path='/missing/old "checkout",one\backup/state/domains/portable.example.com/mtls'
other_path='/another/checkout/state/domains/portable.example.com/mtls'

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function write_mtls() {
  printf 'enabled,directory\n' >"$1"
  csv_join_row "$2" "$3" >>"$1"
}
function reset_fixture() {
  rm -rf "$prepared"
  mkdir -p "$domain/config" "$domain/runtime/applied"
  write_mtls "$domain/runtime/applied/mtls.csv" yes "$old_path"
}

# Portability may replace a saved owned location; it must not turn unrelated
# pending edits into a valid destination path or discard their enabled value.
for scenario in matching unrelated malformed malformed-tail duplicate-tail cross-owner; do
  reset_fixture
  case "$scenario" in
  matching)
    # Reordered fields and quoted source roots use the same named CSV codec.
    printf 'directory,enabled\n' >"$domain/config/mtls.csv"
    csv_join_row "$old_path" no >>"$domain/config/mtls.csv"
    ;;
  unrelated) write_mtls "$domain/config/mtls.csv" no "$other_path" ;;
  malformed) printf '%s\n' 'enabled,directory' 'no,"unfinished' >"$domain/config/mtls.csv" ;;
  malformed-tail | duplicate-tail)
    write_mtls "$domain/config/mtls.csv" no "$old_path"
    if [ "$scenario" = malformed-tail ]; then
      printf '%s\n' 'no,"unfinished' >>"$domain/config/mtls.csv"
    else
      csv_join_row no "$old_path" >>"$domain/config/mtls.csv"
    fi
    ;;
  cross-owner) write_mtls "$domain/config/mtls.csv" no /missing/state/domains/another.example.com/mtls ;;
  esac
  cp "$domain/config/mtls.csv" "$TEST_WORK/before-draft"
  _domain_restore_normalize_mtls "$prepared"
  [ "$(test_csv_field "$domain/runtime/applied/mtls.csv" directory)" = '' ] || fail_test "$scenario: historical applied path was not normalized"
  [ "$(test_csv_field "$domain/runtime/applied/mtls.csv" enabled)" = yes ] || fail_test "$scenario: normalization disabled applied mTLS"
  if [ "$scenario" = matching ]; then
    [ "$(test_csv_field "$domain/config/mtls.csv" directory)" = '' ] || fail_test 'Matching draft path was not normalized'
    [ "$(test_csv_field "$domain/config/mtls.csv" enabled)" = no ] || fail_test 'Normalization activated a pending mTLS disable edit'
  else
    cmp -s "$TEST_WORK/before-draft" "$domain/config/mtls.csv" || fail_test "$scenario: normalization rewrote unrelated draft bytes"
  fi
done

for scenario in malformed-tail duplicate-tail; do
  reset_fixture
  if [ "$scenario" = malformed-tail ]; then
    printf '%s\n' 'yes,"unfinished' >>"$domain/runtime/applied/mtls.csv"
  else
    csv_join_row yes "$old_path" >>"$domain/runtime/applied/mtls.csv"
  fi
  cp "$domain/runtime/applied/mtls.csv" "$TEST_WORK/before-applied"
  _domain_restore_normalize_mtls "$prepared"
  cmp -s "$TEST_WORK/before-applied" "$domain/runtime/applied/mtls.csv" || fail_test "$scenario: normalization partially consumed an invalid accepted table"
done

# Without an accepted historical location there is no basis for rebinding an
# editable absolute path, including a domain that has never been applied.
for scenario in blank-applied draft-only; do
  reset_fixture
  write_mtls "$domain/config/mtls.csv" no "$old_path"
  if [ "$scenario" = blank-applied ]; then
    write_mtls "$domain/runtime/applied/mtls.csv" yes ''
  else
    rm -rf "$domain/runtime/applied"
  fi
  cp "$domain/config/mtls.csv" "$TEST_WORK/before-draft"
  _domain_restore_normalize_mtls "$prepared"
  cmp -s "$TEST_WORK/before-draft" "$domain/config/mtls.csv" || fail_test "$scenario: normalization guessed a source location"
done

# Strict candidate validation handles these rejected inputs. The relocation
# helper must leave their bytes intact rather than make them appear owned.
for invalid in /external/mtls /old/state/domains/another.example.com/mtls /old/state/../state/domains/portable.example.com/mtls /old/./state/domains/portable.example.com/mtls /old//state/domains/portable.example.com/mtls domains/portable.example.com/mtls $'/old/\001state/domains/portable.example.com/mtls'; do
  reset_fixture
  write_mtls "$domain/runtime/applied/mtls.csv" yes "$invalid"
  cp "$domain/runtime/applied/mtls.csv" "$TEST_WORK/before-applied"
  _domain_restore_normalize_mtls "$prepared"
  cmp -s "$TEST_WORK/before-applied" "$domain/runtime/applied/mtls.csv" || fail_test "Normalization legitimized an invalid applied path: $invalid"
done

# Historical backup codecs run before path normalization. Preserve the source
# location through each codec, then normalize only its same-location draft.
for format in 2 3 4; do
  reset_fixture
  for part in config runtime/applied; do
    directory="$domain/$part"
    enabled=yes
    [ "$part" != config ] || enabled=no
    if [ "$format" = 2 ]; then
      printf 'key,value\nschema_version,2\nrole,backend\ntarget,\n' >"$directory/domain.csv"
      printf 'key,value\nenabled,%s\n' "$enabled" >"$directory/mtls.csv"
      csv_join_row directory "$old_path" >>"$directory/mtls.csv"
    else
      printf 'schema_version,role,target\n%s,backend,\n' "$format" >"$directory/domain.csv"
      write_mtls "$directory/mtls.csv" "$enabled" "$old_path"
    fi
  done
  _domain_restore_convert_legacy_domains "$prepared" "$format"
  [ "$(test_csv_field "$domain/runtime/applied/mtls.csv" directory)" = "$old_path" ] || fail_test "Format $format conversion lost its accepted owned location"
  _domain_restore_normalize_mtls "$prepared"
  [ "$(test_csv_field "$domain/runtime/applied/mtls.csv" directory)" = '' ] || fail_test "Format $format accepted location was not normalized"
  [ "$(test_csv_field "$domain/config/mtls.csv" directory)" = '' ] || fail_test "Format $format matching draft location was not normalized"
  [ "$(test_csv_field "$domain/runtime/applied/mtls.csv" enabled)" = yes ] || fail_test "Format $format normalization disabled applied mTLS"
  [ "$(test_csv_field "$domain/config/mtls.csv" enabled)" = no ] || fail_test "Format $format normalization activated a pending mTLS disable edit"
done
TEST_COMPLETE=true
printf '[PASS] mTLS relocation preserves unrelated, malformed and unapplied drafts and unsafe accepted paths\n'
