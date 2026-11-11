#!/usr/bin/env bash
# Fixture roots and journal state are consumed by sourced production helpers.
# shellcheck disable=SC2034
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-draft-trees.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'exec 3>&-; rm -rf "$TEST_WORK"' EXIT
for module in config utils backups domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
STATE_DIR="$TEST_WORK/source-state"
destination="$STATE_DIR/domains/example.com/config"
candidate="$TEST_WORK/candidate"
mkdir -p "$candidate/notes/empty" "$candidate/.editor"
printf 'schema_version,role,target\n5,certificate-only,\n' >"$candidate/domain.csv"
printf 'restored todo\n' >"$candidate/notes/todo"
printf 'unfinished,"draft\n' >"$candidate/.editor/unsaved.csv"
printf '\001\000\377' >"$candidate/.scratch"
chmod 400 "$candidate/notes/todo"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function reject_tree() {
  if _domain_config_draft_tree_guard "$1" >"$TEST_WORK/rejected" 2>&1; then fail_test "Accepted unsafe draft tree: $1"; fi
}
function prepare_source() {
  exec 3>&-
  rm -rf "$destination"
  DOMAIN_CONFIG_RUNTIME_JOURNAL="$TEST_WORK/journal-$1"
  mkdir -p "$destination/notes/empty" "$DOMAIN_CONFIG_RUNTIME_JOURNAL"
  printf 'schema_version,role,target\n5,certificate-only,\n' >"$destination/domain.csv"
  printf 'original todo\n' >"$destination/notes/todo"
  expected="$(_domain_config_draft_tree_fingerprint "$destination")"
}

# Tree fingerprints distinguish nested bytes, hidden files and empty folders.
fingerprint="$(_domain_config_draft_tree_fingerprint "$candidate")"
_domain_config_draft_tree_copy "$candidate" "$TEST_WORK/copied"
[ "$fingerprint" = "$(_domain_config_draft_tree_fingerprint "$TEST_WORK/copied")" ] || fail_test 'Copied tree fingerprint differs.'
cmp -s "$candidate/.scratch" "$TEST_WORK/copied/.scratch" || fail_test 'Copy changed binary draft bytes.'
[ "$(_restore_intake_file_mode "$TEST_WORK/copied/notes/todo")" = 00400 ] || fail_test 'Copy widened a read-only draft file.'
rmdir "$TEST_WORK/copied/notes/empty"
[ "$fingerprint" != "$(_domain_config_draft_tree_fingerprint "$TEST_WORK/copied")" ] || fail_test 'Fingerprint omitted an empty directory.'
mkdir "$TEST_WORK/copied/notes/empty"
printf 'changed\n' >>"$TEST_WORK/copied/.scratch"
[ "$fingerprint" != "$(_domain_config_draft_tree_fingerprint "$TEST_WORK/copied")" ] || fail_test 'Fingerprint omitted a hidden file.'
ln -s "$TEST_WORK/outside" "$candidate/notes/link"
reject_tree "$candidate"
rm "$candidate/notes/link"
mkfifo "$candidate/notes/pipe"
reject_tree "$candidate"
rm "$candidate/notes/pipe"
if _domain_config_draft_tree_fingerprint "$candidate/notes/../" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Traversal path accepted.'; fi
if _domain_config_dir_guard "$candidate" >"$TEST_WORK/rejected" 2>&1; then fail_test 'Opaque restore support relaxed flat model validation.'; fi

# Old journals have no new marker and keep their historical flat codec.
mkdir "$TEST_WORK/old-source-record"
[ "$(_domain_config_source_layout "$TEST_WORK/old-source-record")" = flat ] || fail_test 'Historical journal did not default to flat.'
printf 'tree\nextra\n' >"$TEST_WORK/old-source-record/layout"
if _domain_config_source_layout "$TEST_WORK/old-source-record" >/dev/null 2>&1; then fail_test 'Ambiguous source layout marker accepted.'; fi

prepare_source unchanged_rollback
_domain_config_source_publish example.com "$candidate" "$expected" tree
_domain_config_source_verify
domain_config_source_rollback
[ "$(cat "$destination/notes/todo")" = 'original todo' ] || fail_test 'Rollback lost the previous nested draft.'

prepare_source before_publication
printf 'editor before publication\n' >>"$destination/notes/todo"
if _domain_config_source_publish example.com "$candidate" "$expected" tree >"$TEST_WORK/rejected" 2>&1; then fail_test 'Publication ignored a nested edit after capture.'; fi
grep -q 'editor before publication' "$destination/notes/todo" || fail_test 'Publication replaced the newer draft.'

prepare_source held_descriptor
exec 3>>"$destination/notes/todo"
_domain_config_source_publish example.com "$candidate" "$expected" tree
printf 'editor after swap\n' >&3
if _domain_config_source_verify >"$TEST_WORK/rejected" 2>&1; then fail_test 'Commit ignored a nested open-descriptor edit.'; fi
domain_config_source_rollback
grep -q 'editor after swap' "$destination/notes/todo" || fail_test 'Rollback lost the detached nested edit.'
printf 'editor after rollback\n' >&3
grep -q 'editor after rollback' "$destination/notes/todo" || fail_test 'Rollback replaced the original nested inode.'
domain_config_source_rollback
exec 3>&-

prepare_source edited_replacement
_domain_config_source_publish example.com "$candidate" "$expected" tree
printf 'new editor file\n' >"$destination/.editor/new-note"
if _domain_config_source_verify >"$TEST_WORK/rejected" 2>&1; then fail_test 'Commit ignored an added nested file.'; fi
domain_config_source_rollback
[ "$(cat "$destination/.editor/new-note")" = 'new editor file' ] || fail_test 'Rollback overwrote the edited replacement tree.'

prepare_source both_changed
exec 3>>"$destination/notes/todo"
_domain_config_source_publish example.com "$candidate" "$expected" tree
printf 'detached edit\n' >&3
printf 'replacement edit\n' >"$destination/.editor/new-note"
if domain_config_source_rollback >"$TEST_WORK/rejected" 2>&1; then fail_test 'Conflicting nested copies were reported as recovered.'; fi
grep -q 'detached edit' "$DOMAIN_CONFIG_RUNTIME_JOURNAL/sources/example.com/detached/notes/todo" || fail_test 'Conflicting original edit was lost.'
grep -q 'replacement edit' "$destination/.editor/new-note" || fail_test 'Conflicting replacement edit was lost.'
exec 3>&-

# Exercise public backup intake and restore with a valid applied snapshot and
# opaque draft-only contents, then prove those contents remain unapplied.
checkout="$TEST_WORK/checkout"
mkdir "$checkout"
cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$ROOT_DIR/completion" "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$checkout/"
BIN="$checkout/dockistrate.sh"
domain="$checkout/state/domains/example.com"
function run_cli() {
  SKIP_DOCKER_CHECKS=true "$BIN" "$@" >"$TEST_WORK/output" 2>&1 || { cat "$TEST_WORK/output" >&2; fail_test "Command failed: $*"; }
}
run_cli init-domain-config example.com --kind certificate-only
run_cli apply-domain-config example.com
mkdir -p "$domain/config/notes/empty" "$domain/config/.editor"
printf 'backup todo\n' >"$domain/config/notes/todo"
printf 'unfinished,"draft\n' >"$domain/config/.editor/unsaved.csv"
printf '\001\000\377' >"$domain/config/.scratch"
cp -R "$domain/config" "$TEST_WORK/expected-draft"
cp -R "$domain/runtime/applied" "$TEST_WORK/expected-applied"
run_cli create-backup draft-tree-round-trip
backup="$(cat "$checkout/state/backups/last_full_backup.txt")"
printf 'newer todo\n' >"$domain/config/notes/todo"
mkdir -p "$domain/config/newer-empty"
printf 'newer hidden edit\n' >"$domain/config/.editor/newer"
run_cli restore-backup "$backup"
diff -r "$TEST_WORK/expected-draft" "$domain/config" >/dev/null || fail_test 'Public restore changed opaque draft bytes or structure.'
diff -r "$TEST_WORK/expected-applied" "$domain/runtime/applied" >/dev/null || fail_test 'Public restore applied an opaque draft.'
run_cli status
grep -q 'invalid draft' "$TEST_WORK/output" || fail_test 'Restored nested draft was not marked invalid.'
if SKIP_DOCKER_CHECKS=true "$BIN" apply-domain-config example.com >"$TEST_WORK/output" 2>&1; then fail_test 'Ordinary apply accepted nested draft files.'; fi
diff -r "$TEST_WORK/expected-applied" "$domain/runtime/applied" >/dev/null || fail_test 'Rejected apply changed the applied snapshot.'
printf '[tests] domain_config_draft_trees.sh: PASS\n'
