#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils backups; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore-stat-traps.XXXXXXXX")"
TEST_WORK="$(cd -P "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
mkdir "$TEST_WORK/bin"
printf 'hello\n' >"$TEST_WORK/input"
# A minimal BSD-stat fixture keeps the probe/transaction regression independent
# of the host's native stat dialect. Other tests cover real filesystem identity
# and fstat behavior; this one isolates expected failure and trap propagation.
cat >"$TEST_WORK/bin/stat" <<'STAT'
#!/usr/bin/env bash
set -Eeuo pipefail
[ "${RESTORE_PROBE_FAIL_ALL:-false}" != true ] || exit 1
[ "${1:-}" != -L ] || shift
case "${1:-}" in
-c) exit 1 ;;
-f)
  case "${2:-}" in
  '%p') printf '100600\n' ;;
  '%d:%i') printf '42:40\n' ;;
  '%d:%i:%z:%m:%c') printf '42:43:6:10:11\n' ;;
  '%d:%i:%z:%m:%c:%p')
    if [ "${RESTORE_PROBE_BAD_TYPE:-false}" = true ]; then printf '42:43:6:10:11:40700\n'; else printf '42:43:6:10:11:100600\n'; fi
    ;;
  *) printf 'Unexpected stat format: %s\n' "${2:-}" >&2; exit 2 ;;
  esac
  ;;
*) printf 'Unexpected stat invocation\n' >&2; exit 2 ;;
esac
STAT
chmod 700 "$TEST_WORK/bin/stat"
PATH="$TEST_WORK/bin:$PATH"
export PATH
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function _test_rollback() {
  printf 'unexpected rollback: subshell=%s stack=%s\n' "$BASH_SUBSHELL" "${FUNCNAME[*]-}" >>"$TEST_WORK/rollback"
  return 1
}
function _test_install_transaction() { trap '_test_rollback' ERR EXIT; }
function _test_read_helpers() {
  local value=""
  # Match restore's nested command substitutions under an active transaction.
  # Bash 3 invokes inherited ERR for `command stat` despite an OR-list guard
  # unless the read-only probe explicitly resets its own inherited ERR trap.
  value="$(_restore_intake_file_mode "$TEST_WORK/input")" || return 1
  [ "$value" = 00600 ] || return 1
  value="$(_restore_intake_stat "$TEST_WORK/input" false)" || return 1
  [ "$value" = 42:43:6:10:11 ] || return 1
  value="$(_backup_directory_identity "$TEST_WORK")" || return 1
  [ "$value" = 42:40 ] || return 1
  _restore_intake_copy_regular "$TEST_WORK/input" "$TEST_WORK/copied" 6 'Probe fixture' false || return 1
  cmp -s "$TEST_WORK/input" "$TEST_WORK/copied" || return 1

}
function _test_activate() (
  local original_err="" original_exit=""
  _test_install_transaction
  original_err="$(trap -p ERR)"; original_exit="$(trap -p EXIT)"
  _test_read_helpers || return 1
  [ "$(trap -p ERR)" = "$original_err" ] && [ "$(trap -p EXIT)" = "$original_exit" ] || return 1
  [ ! -s "$TEST_WORK/rollback" ] || return 1
  trap - ERR EXIT
)
function _test_restore() (
  # Match the extra subshell owned by domain_config_restore_backup.
  _test_activate || return 1
)
if ! _test_restore; then
  [ ! -f "$TEST_WORK/rollback" ] || cat "$TEST_WORK/rollback" >&2
  fail_test 'Read-only BSD fallback invoked rollback or changed caller traps'
fi
# After the successful active-transaction check, confirm invalid observations
# still fail closed. A real active transaction should roll back such a failure.
function _test_invalid_metadata() {
  # Failed fallback and nonregular descriptors still fail; trap isolation must
  # not turn inspection failures into accepted metadata or copied payloads.
  if RESTORE_PROBE_FAIL_ALL=true _restore_intake_stat "$TEST_WORK/input" >"$TEST_WORK/error" 2>&1; then return 1; fi
  if RESTORE_PROBE_BAD_TYPE=true _restore_intake_copy_regular "$TEST_WORK/input" "$TEST_WORK/invalid" 6 >"$TEST_WORK/error" 2>&1; then return 1; fi
  [ ! -e "$TEST_WORK/invalid" ] || return 1
  grep -q 'not a regular file' "$TEST_WORK/error" || return 1
}
_test_invalid_metadata || fail_test 'Invalid metadata was accepted or copied'
printf '[PASS] Nested BSD stat probes preserve caller traps and fail closed on invalid metadata\n'
