#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=lib/clean_uninstall/runtime_safety.sh
source "$ROOT_DIR/lib/clean_uninstall/runtime_safety.sh"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_cleanup_identity.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
original_state="$STATE_DIR"
# Keep every command path in this fixture, including private state and backups.
for variable in $(compgen -A variable); do
  case "$variable" in
  *_FILE | *_DIR | *_DB)
    value="${!variable}"
    case "$value" in "$original_state" | "$original_state"/*) printf -v "$variable" '%s' "$FIXTURE/state${value#"$original_state"}" ;; esac
    ;;
  esac
done
BASE_DIR="$FIXTURE"
BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
DOCKER_MOCK_RUNTIME_DIR="$FIXTURE/docker"
DOCKER_MOCK_LOG_FILE="$FIXTURE/docker.log"
PATH="$ROOT_DIR/tests/mocks:$PATH"
export PATH DOCKER_MOCK_RUNTIME_DIR DOCKER_MOCK_LOG_FILE
TOKEN=0123456789abcdef0123456789abcdef
DOMAIN=cleanup-identity.test
CNAME=backend-cleanup-identity.test
function fail() { printf '[Error] %s: %s\n' "$CASE" "$*" >&2; exit 1; }
function prepare_case() {
  CASE="$1"
  _cleanup_runtime_clear_staged_deletes
  rm -rf "$DOCKER_MOCK_RUNTIME_DIR" "$STATE_DIR"
  mkdir -p "$CONFIG_DIR"
  local state_label=""
  state_label="$(_backend_identity_state_dir && printf '.')" || fail 'cannot resolve fixture state root'
  state_label="${state_label%.}"
  ID="$(docker run -d --name "$CNAME" --network dockistrate-net \
    --label com.dockistrate.managed=true --label com.dockistrate.role=backend \
    --label "com.dockistrate.state-dir=$state_label" --label "com.dockistrate.backend-domain=$DOMAIN" \
    --label "com.dockistrate.backend-launch=$TOKEN" nginx:alpine)"
  _backend_identity_store "$DOMAIN" "$ID" "$TOKEN"
  _cleanup_runtime_stage_container_delete "$CNAME" "$DOMAIN" "$ID" "$TOKEN"
  [ "$(docker inspect -f '{{.State.Status}}' "$ID")" = exited ] || fail 'stage did not stop the original ID'
  # Finalization and rollback must retain their own proof after state removal.
  rm -f "$BACKEND_IDENTITY_FILE"
  : >"$DOCKER_MOCK_LOG_FILE"
}
function foreign_container() {
  FOREIGN_ID="$(docker run -d --name "$CNAME" --network foreign-net nginx:alpine)"
  cp "$DOCKER_MOCK_RUNTIME_DIR/$CNAME.meta" "$FIXTURE/foreign.before"
  : >"$DOCKER_MOCK_LOG_FILE"
}
function assert_foreign_untouched() {
  cmp -s "$FIXTURE/foreign.before" "$DOCKER_MOCK_RUNTIME_DIR/$CNAME.meta" || fail 'foreign replacement metadata changed'
  if grep -Eq "^subcommand=(rm|rename|start|stop|restart) .*($CNAME|$FOREIGN_ID)( |$)" "$DOCKER_MOCK_LOG_FILE"; then
    # Rename's destination may be the original name; only its source may act.
    if grep -Eq "^subcommand=(rm -f( -v)?|rename|start|stop|restart) ($CNAME|$FOREIGN_ID)( |$)" "$DOCKER_MOCK_LOG_FILE"; then
      fail 'cleanup acted on the foreign replacement'
    fi
  fi
}
prepare_case finalize_collision
foreign_container
_cleanup_runtime_finalize_staged_deletes >/dev/null
assert_foreign_untouched
if docker inspect -f '{{.Id}}' "$ID" >/dev/null 2>&1; then fail 'owned original was not finalized'; fi
grep -Fxq "subcommand=rm -f -v $ID" "$DOCKER_MOCK_LOG_FILE" || fail 'finalization did not remove pinned ID'
printf '[PASS] cleanup finalization removes only the verified original ID\n'

prepare_case rollback_collision
foreign_container
if _cleanup_runtime_restore_staged_deletes_if_needed >"$FIXTURE/output" 2>&1; then fail 'rollback claimed success while a foreign name blocked recovery'; fi
assert_foreign_untouched
[ "${CLEANUP_RUNTIME_DELETE_COUNT:-0}" -eq 1 ] || fail 'incomplete rollback discarded identity proof'
[ "$(docker inspect -f '{{.State.Status}}' "$ID")" = exited ] || fail 'blocked rollback started the staged original'
printf '[PASS] cleanup rollback preserves foreign name occupant and recovery proof\n'

prepare_case rollback_name_probe_failure
foreign_container
mkdir -p "$FIXTURE/bin"
BACKEND_CLEANUP_DOCKER_MOCK="$ROOT_DIR/tests/mocks/docker"
NAME_PROBE_TRACE="$FIXTURE/name-probe.log"
ERR_TRACE="$FIXTURE/err-trap.log"
: >"$NAME_PROBE_TRACE"
: >"$ERR_TRACE"
export BACKEND_CLEANUP_DOCKER_MOCK NAME_PROBE_TRACE
cat >"$FIXTURE/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = inspect ] && [ "${2:-}" = -f ] && [ "${3:-}" = '{{.Name}}' ]; then
  printf '%s\n' "${4:-}" >>"$NAME_PROBE_TRACE"
  exit 1
fi
exec "$BACKEND_CLEANUP_DOCKER_MOCK" "$@"
MOCK
chmod +x "$FIXTURE/bin/docker"
saved_path="$PATH"
PATH="$FIXTURE/bin:$PATH"
trap 'printf "unexpected ERR trap\n" >>"$ERR_TRACE"' ERR
if _cleanup_runtime_restore_staged_deletes_if_needed >"$FIXTURE/output" 2>&1; then status=0; else status=$?; fi
trap - ERR
PATH="$saved_path"
[ "$status" -ne 0 ] || fail 'failed name lookup reported successful recovery'
[ "$(cat "$NAME_PROBE_TRACE")" = "$ID" ] || fail 'recovery did not inspect the original immutable ID after rename failed'
[ ! -s "$ERR_TRACE" ] || fail 'handled recovery name lookup failure invoked inherited ERR trap'
assert_foreign_untouched
[ "${CLEANUP_RUNTIME_DELETE_COUNT:-0}" -eq 1 ] || fail 'failed name lookup discarded recovery proof'
[ "$(docker inspect -f '{{.State.Status}}' "$ID")" = exited ] || fail 'failed name lookup restarted the staged original'
printf '[PASS] cleanup recovery handles name lookup failure without inherited ERR trap\n'

prepare_case rollback_success
_cleanup_runtime_restore_staged_deletes_if_needed
[ "$(docker inspect -f '{{.Id}}' "$CNAME")" = "$ID" ] || fail 'rollback restored a different container'
[ "$(docker inspect -f '{{.State.Status}}' "$ID")" = running ] || fail 'rollback did not restore running state'
grep -Fxq "subcommand=start $ID" "$DOCKER_MOCK_LOG_FILE" || fail 'rollback did not start pinned ID'
printf '[PASS] cleanup rollback restores verified original without the sidecar\n'

prepare_case finalize_absent
docker rm -f "$ID" >/dev/null
: >"$DOCKER_MOCK_LOG_FILE"
_cleanup_runtime_finalize_staged_deletes
if grep -Eq '^subcommand=(rm|rename|start) ' "$DOCKER_MOCK_LOG_FILE"; then fail 'finalization mutated runtime after proven absence'; fi
printf '[PASS] cleanup finalization accepts a proven absent original ID\n'

prepare_case finalize_mismatch
backup_name="$(docker inspect -f '{{.Name}}' "$ID")"
sed 's/com.dockistrate.role=backend/com.dockistrate.role=foreign/' "$DOCKER_MOCK_RUNTIME_DIR/${backup_name#/}.meta" >"$FIXTURE/meta"
cat "$FIXTURE/meta" >"$DOCKER_MOCK_RUNTIME_DIR/${backup_name#/}.meta"
: >"$DOCKER_MOCK_LOG_FILE"
if _cleanup_runtime_finalize_staged_deletes >"$FIXTURE/output" 2>&1; then fail 'finalization accepted changed ownership'; fi
if grep -Eq '^subcommand=(rm|rename|start|stop) ' "$DOCKER_MOCK_LOG_FILE"; then fail 'mismatched original reached a mutation'; fi
[ "${CLEANUP_RUNTIME_DELETE_COUNT:-0}" -eq 1 ] || fail 'ownership mismatch discarded recovery proof'
printf '[PASS] cleanup finalization refuses ownership mismatch\n'

prepare_case finalize_remove_failure
function remove_container_and_anonymous_volumes() { return 1; }
if _cleanup_runtime_finalize_staged_deletes >"$FIXTURE/output" 2>&1; then fail 'failed permanent removal reported success'; fi
[ "$(docker inspect -f '{{.Id}}' "$CNAME")" = "$ID" ] || fail 'failed permanent removal lost original identity'
[ "$(docker inspect -f '{{.State.Status}}' "$ID")" = running ] || fail 'failed permanent removal did not restore running state'
grep -Fxq "subcommand=start $ID" "$DOCKER_MOCK_LOG_FILE" || fail 'failed removal recovery did not use original ID'
printf '[PASS] cleanup deletion failure restores exact original identity\n'

function run_cleanup_state_cases() (
  local module="" command="" identity_mode="" variant=""
  for module in nginx ports tls mtls headers http_version security_rules nginx_directives clean_uninstall; do
    # shellcheck disable=SC1090
    source "$ROOT_DIR/lib/$module.sh"
  done
  # Restore the production remover overridden by the finalization failure case.
  # shellcheck source=lib/utils/docker.sh
  source "$ROOT_DIR/lib/utils/docker.sh"
  SKIP_DOCKER_CHECKS=false
  INTERACTIVE=false
  # Exercise real cleanup/state functions within an existing outer transaction;
  # archive/render behavior is covered separately by the transaction suites.
  function transaction_is_active() { return 0; }
  function create_backup() { :; }
  function capture_docker_logs() { :; }
  function update_nginx_config() { :; }
  function log_msg() { :; }
  function confirm_prompt() { return 0; }
  function nginx_container_conflict_exists() { return 1; }
  function nginx_container_is_managed() { return 1; }

  function prepare_state_case() {
    CASE="$1"
    _cleanup_runtime_clear_staged_deletes
    rm -rf "$STATE_DIR" "$DOCKER_MOCK_RUNTIME_DIR" "$FIXTURE/config.before" "$FIXTURE/docker.before"
    mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CERTS_DIR" "$DOCKER_MOCK_RUNTIME_DIR"
    state_csv_ensure_all_state_files
    ID=""
    : >"$DOCKER_MOCK_LOG_FILE"
  }
  function configured_backend() {
    state_backend_ports_row_backend "$DOMAIN" 10.0.0.5:80 dockistrate-net >>"$BACKEND_PORTS_FILE"
  }
  function owned_backend() {
    local state_label=""
    state_label="$(_backend_identity_state_dir && printf '.')" || fail 'cannot resolve fixture state root'
    state_label="${state_label%.}"
    ID="$(docker run -d --name "$CNAME" --network dockistrate-net \
      --label com.dockistrate.managed=true --label com.dockistrate.role=backend \
      --label "com.dockistrate.state-dir=$state_label" --label "com.dockistrate.backend-domain=$DOMAIN" \
      --label "com.dockistrate.backend-launch=$TOKEN" nginx:alpine)"
    _backend_identity_store "$DOMAIN" "$ID" "$TOKEN"
  }
  function save_cleanup_state() {
    cp -R "$CONFIG_DIR" "$FIXTURE/config.before"
    cp -R "$DOCKER_MOCK_RUNTIME_DIR" "$FIXTURE/docker.before"
    : >"$DOCKER_MOCK_LOG_FILE"
  }
  function assert_cleanup_untouched() {
    diff -r "$FIXTURE/config.before" "$CONFIG_DIR" >/dev/null || fail 'refused cleanup changed saved state'
    diff -r "$FIXTURE/docker.before" "$DOCKER_MOCK_RUNTIME_DIR" >/dev/null || fail 'refused cleanup changed runtime'
    if grep -Eq '^subcommand=(run|rm|rename|start|stop|restart|network (create|connect|disconnect|rm)) ' "$DOCKER_MOCK_LOG_FILE"; then
      fail 'unproved cleanup attempted a runtime mutation'
    fi
  }
  function invoke_cleanup() (
    case "$1" in
    remove_backend) remove_backend --yes "$DOMAIN" ;;
    clean_all) clean_all "$DOMAIN" ;;
    uninstall_all) uninstall_all --scope backend ;;
    esac
  )
  function assert_state_removed() {
    if backend_exists "$DOMAIN"; then fail 'cleanup retained the backend row'; fi
    _backend_identity_read "$DOMAIN" true || fail 'cleanup left invalid identity state'
    [ "$BACKEND_IDENTITY_FOUND" -eq 0 ] || fail 'cleanup retained the identity row'
  }

  for command in remove_backend clean_all uninstall_all; do
    for identity_mode in absent header_only; do
      prepare_state_case "${command}_legacy_${identity_mode}"
      configured_backend
      [ "$identity_mode" != absent ] || rm -f "$BACKEND_IDENTITY_FILE"
      invoke_cleanup "$command" >"$FIXTURE/output" 2>&1 || fail 'legacy empty-name cleanup failed'
      assert_state_removed
      if grep -Eq '^subcommand=(run|rm|rename|start|stop|restart|network (create|connect|disconnect|rm)) ' "$DOCKER_MOCK_LOG_FILE"; then
        fail 'legacy state-only cleanup mutated runtime'
      fi
      grep -Fq -- "--filter name=^/${CNAME}$" "$DOCKER_MOCK_LOG_FILE" || fail 'legacy cleanup did not prove the canonical name empty'
      printf '[PASS] %s permits legacy state-only cleanup with %s identity file\n' "$command" "$identity_mode"
    done
    for variant in foreign ps_failure malformed duplicate; do
      prepare_state_case "${command}_legacy_${variant}"
      configured_backend
      case "$variant" in
      foreign) foreign_container ;;
      malformed) printf '%s,bad-id,%s\n' "$DOMAIN" "$TOKEN" >>"$BACKEND_IDENTITY_FILE" ;;
      duplicate)
        _backend_identity_store "$DOMAIN" "$(printf '%064d' 1)" "$TOKEN"
        printf '%s,%064d,%s\n' "$DOMAIN" 1 "$TOKEN" >>"$BACKEND_IDENTITY_FILE"
        ;;
      ps_failure)
        function docker() {
          if [ "${1:-}" = ps ]; then return 1; fi
          command docker "$@"
        }
        ;;
      esac
      save_cleanup_state
      if invoke_cleanup "$command" >"$FIXTURE/output" 2>&1; then fail 'unsafe legacy cleanup succeeded'; fi
      [ "$variant" != ps_failure ] || unset -f docker
      assert_cleanup_untouched
      printf '[PASS] %s refuses legacy cleanup with %s\n' "$command" "$variant"
    done
  done

  for command in clean_all uninstall_all; do
    prepare_state_case "${command}_orphan_owned"
    owned_backend
    : >"$DOCKER_MOCK_LOG_FILE"
    invoke_cleanup "$command" >"$FIXTURE/output" 2>&1 || fail 'owned sidecar-only cleanup failed'
    assert_state_removed
    if docker inspect -f '{{.Id}}' "$ID" >/dev/null 2>&1; then fail 'sidecar-only cleanup orphaned the managed container'; fi
    grep -Fxq "subcommand=rm -f -v $ID" "$DOCKER_MOCK_LOG_FILE" || fail 'sidecar-only cleanup did not remove the immutable ID'
    printf '[PASS] %s cleans sidecar-only managed container by immutable ID\n' "$command"

    for variant in foreign malformed duplicate; do
      prepare_state_case "${command}_orphan_${variant}"
      owned_backend
      case "$variant" in
      foreign) docker rm -f "$ID" >/dev/null; foreign_container ;;
      malformed) printf '%s,bad-id,%s\n' foreign.test "$TOKEN" >>"$BACKEND_IDENTITY_FILE" ;;
      duplicate) printf '%s,%s,%s\n' "$DOMAIN" "$ID" "$TOKEN" >>"$BACKEND_IDENTITY_FILE" ;;
      esac
      save_cleanup_state
      if invoke_cleanup "$command" >"$FIXTURE/output" 2>&1; then fail 'unsafe sidecar-only cleanup succeeded'; fi
      assert_cleanup_untouched
      printf '[PASS] %s preserves sidecar-only proof with %s\n' "$command" "$variant"
    done
  done

  prepare_state_case uninstall_configured_identity_deduplicated
  configured_backend
  owned_backend
  : >"$DOCKER_MOCK_LOG_FILE"
  invoke_cleanup uninstall_all >"$FIXTURE/output" 2>&1 || fail 'configured identity uninstall failed'
  [ "$(grep -Fxc "subcommand=rm -f -v $ID" "$DOCKER_MOCK_LOG_FILE")" -eq 1 ] || fail 'uninstall did not deduplicate configured and sidecar domains'
  printf '[PASS] uninstall deduplicates configured and sidecar domain ownership\n'

  # Repeat the supported repair paths with real transaction snapshots, staged
  # immutable-ID deletion, and commit finalization instead of an outer stub.
  # shellcheck source=lib/backups.sh
  source "$ROOT_DIR/lib/backups.sh"
  function create_backup() { :; }
  function capture_docker_logs() { :; }
  for command in remove_backend clean_all uninstall_all; do
    prepare_state_case "${command}_transaction_legacy_absent"
    configured_backend
    rm -f "$BACKEND_IDENTITY_FILE"
    invoke_cleanup "$command" >"$FIXTURE/output" 2>&1 || fail 'transactional legacy state-only cleanup failed'
    assert_state_removed
    [ -s "$LAST_POST_BACKUP_FILE" ] || fail 'legacy cleanup did not commit a real transaction'
    if grep -Eq '^subcommand=(run|rm|rename|start|stop|restart|network (create|connect|disconnect|rm)) ' "$DOCKER_MOCK_LOG_FILE"; then
      fail 'transactional legacy state-only cleanup mutated runtime'
    fi
    printf '[PASS] %s commits legacy state-only cleanup in a real transaction\n' "$command"
  done
  for command in clean_all uninstall_all; do
    for variant in owned occupied_name; do
      prepare_state_case "${command}_transaction_orphan_${variant}"
      owned_backend
      if [ "$variant" = occupied_name ]; then
        docker rename "$ID" "${CNAME}-original" >/dev/null
        foreign_container
      fi
      : >"$DOCKER_MOCK_LOG_FILE"
      invoke_cleanup "$command" >"$FIXTURE/output" 2>&1 || fail 'transactional sidecar-only cleanup failed'
      assert_state_removed
      [ -s "$LAST_POST_BACKUP_FILE" ] || fail 'orphan cleanup did not commit a real transaction'
      if docker inspect -f '{{.Id}}' "$ID" >/dev/null 2>&1; then fail 'transaction orphaned the managed ID'; fi
      grep -Fxq "subcommand=rm -f -v $ID" "$DOCKER_MOCK_LOG_FILE" || fail 'transaction finalization did not remove pinned ID'
      [ "$variant" != occupied_name ] || assert_foreign_untouched
      printf '[PASS] %s commits sidecar-only cleanup with %s by immutable ID\n' "$command" "$variant"
    done
  done
)

run_cleanup_state_cases

printf '%s\n' 'Backend cleanup identity checks passed.'
