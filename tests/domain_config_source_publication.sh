#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/domain_config/common.sh"
source "$ROOT_DIR/lib/domain_config/publication.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain_source_publication.XXXXXXXX")"
trap 'exec 3>&-; rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"
destination="$STATE_DIR/domains/example.com/config"
candidate="$TEST_WORK/candidate"
mkdir -p "$candidate"
printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp2,,,,,\n' >"$candidate/settings.csv"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function prepare_source() {
  DOMAIN_CONFIG_RUNTIME_JOURNAL="$TEST_WORK/journal-$1"
  mkdir -p "$destination" "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  printf 'http_version,client_ip_header,proxy_ip_header,acl_policy,acl_status,security_rule_status\nhttp1.1,,,,,\n' >"$destination/settings.csv"
  expected="$(_domain_config_input_fingerprint "$destination")"
  exec 3>>"$destination/settings.csv"
}

prepare_source held_descriptor
_domain_config_source_publish example.com "$candidate" "$expected"
printf 'editor,after-swap\n' >&3
if _domain_config_source_verify >"$TEST_WORK/error" 2>&1; then fail_test 'Commit ignored edits through the old descriptor'; fi
domain_config_source_rollback
grep -qx 'editor,after-swap' "$destination/settings.csv" || fail_test 'Rollback discarded edits to the detached original'
printf 'editor,after-rollback\n' >&3
grep -qx 'editor,after-rollback' "$destination/settings.csv" || fail_test 'Rollback did not restore the original file inode'
domain_config_source_rollback
grep -qx 'editor,after-rollback' "$destination/settings.csv" || fail_test 'Repeated rollback discarded later edits'
exec 3>&-

prepare_source removal
_domain_config_source_publish example.com '' "$expected"
printf 'editor,after-removal\n' >&3
if _domain_config_source_verify >"$TEST_WORK/error" 2>&1; then fail_test 'Removal commit ignored old-descriptor edits'; fi
domain_config_source_rollback
grep -qx 'editor,after-removal' "$destination/settings.csv" || fail_test 'Removal rollback discarded the later edit'
exec 3>&-

prepare_source both_changed
_domain_config_source_publish example.com "$candidate" "$expected"
printf 'editor,original-file\n' >&3
printf 'editor,replacement-file\n' >>"$destination/settings.csv"
record="$DOMAIN_CONFIG_RUNTIME_JOURNAL/sources/example.com"
if domain_config_source_rollback >"$TEST_WORK/error" 2>&1; then fail_test 'Conflicting editor copies were reported as recovered'; fi
grep -qx 'editor,original-file' "$record/detached/settings.csv" || fail_test 'Conflict recovery discarded original-file edits'
grep -qx 'editor,replacement-file' "$destination/settings.csv" || fail_test 'Conflict recovery discarded replacement-file edits'
grep -Fq "$record/detached" "$TEST_WORK/error" || fail_test 'Conflict recovery did not identify the retained copy'
exec 3>&-

# Only explicit config/all uninstall may finish without publishing an empty
# inventory into the configuration directory it deliberately removed.
terminal_work="$TEST_WORK/terminal"
CONFIG_DIR="$TEST_WORK/removed-config"
mkdir -p "$terminal_work"
: >"$terminal_work/before-domains"
PUBLISHED_APPLIED=false EXPORT_DOMAIN=false
function _domain_config_export_tree() {
  mkdir -p "$1"
  if [ "$EXPORT_DOMAIN" = true ]; then mkdir -p "$1/retained.example.com/config"; fi
}
function domain_config_validate_tree() { :; }
function _domain_config_activate_deferred_render() { :; }
function _domain_config_same() { return 0; }
function _domain_config_publish_applied() { PUBLISHED_APPLIED=true; }
DOMAIN_CONFIG_MUTATION_COMMAND=uninstall-all DOMAIN_CONFIG_TERMINAL_UNINSTALL=true
_domain_config_sync_command "$terminal_work"
[ "$PUBLISHED_APPLIED" = false ] || fail_test 'Terminal uninstall republished the deleted inventory'
[ ! -e "$CONFIG_DIR" ] || fail_test 'Terminal uninstall recreated the configuration directory'
DOMAIN_CONFIG_TERMINAL_UNINSTALL=false
_domain_config_sync_command "$terminal_work"
[ "$PUBLISHED_APPLIED" = true ] || fail_test 'Ordinary publication skipped the inventory because its directory was missing'
DOMAIN_CONFIG_TERMINAL_UNINSTALL=true DOMAIN_CONFIG_MUTATION_COMMAND=remove-backend
if _domain_config_sync_command "$terminal_work"; then fail_test 'A different command claimed terminal uninstall'; fi
DOMAIN_CONFIG_MUTATION_COMMAND=uninstall-all
mkdir -p "$CONFIG_DIR"
if _domain_config_sync_command "$terminal_work"; then fail_test 'Terminal uninstall retained its configuration directory'; fi
rmdir "$CONFIG_DIR"
EXPORT_DOMAIN=true
if _domain_config_sync_command "$terminal_work" >"$TEST_WORK/error" 2>&1; then fail_test 'Terminal uninstall discarded the inventory of a retained domain'; fi

printf '[PASS] source publication preserves open-editor changes and terminal uninstall guards\n'
