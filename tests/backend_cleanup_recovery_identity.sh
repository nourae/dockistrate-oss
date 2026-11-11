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
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_cleanup_recovery_identity.XXXXXX")"
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

# Each case inherits these production functions in its own subshell.
for module in nginx ports tls mtls headers http_version security_rules nginx_directives clean_uninstall backups; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
# shellcheck source=lib/utils/docker.sh
source "$ROOT_DIR/lib/utils/docker.sh"

function run_recovery_case() (
  CASE="recovery_$1"
  local variant="$1" state_label="" original_backup=""
  local second_domain=cleanup-second.test second_id="" second_token=fedcba9876543210fedcba9876543210
  function create_backup() { :; }
  function capture_docker_logs() { :; }
  function update_nginx_config() { :; }
  function log_msg() { :; }
  function load_config() { :; }
  function confirm_prompt() { return 0; }
  function nginx_container_conflict_exists() { return 1; }
  function nginx_container_is_managed() { return 1; }
  # Keep command-level failures observable to their conditional caller while
  # retaining the production backup, commit, lock and rollback implementations.
  function begin_transaction() { begin_transaction_return "$@"; }
  SKIP_DOCKER_CHECKS=false
  INTERACTIVE=false
  _cleanup_runtime_clear_staged_deletes
  rm -rf "$STATE_DIR" "$DOCKER_MOCK_RUNTIME_DIR"
  mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$BACKUP_DIR" "$LOG_DIR" "$CERTS_DIR"
  # Command cases traverse the full configuration; helper cases snapshot the
  # routing and identity files they operate on through the real transaction API.
  case "$variant" in
  command_clean | command_config | command_all | original_commit_clean | original_commit_uninstall)
    state_csv_ensure_all_state_files
    ;;
  *)
    state_csv_require_file "$BACKEND_PORTS_FILE" "$STATE_BACKEND_PORTS_HEADER"
    state_csv_require_file "$BACKEND_IDENTITY_FILE" "$STATE_BACKEND_IDENTITY_HEADER"
    ;;
  esac
  state_label="$(_backend_identity_state_dir && printf '.')" || fail 'cannot resolve recovery state root'
  state_label="${state_label%.}"
  function seed_recovery_backend() {
    local domain="$1" token="$2"
    ID="$(docker run -d --name "backend-$domain" --network dockistrate-net \
      --label com.dockistrate.managed=true --label com.dockistrate.role=backend \
      --label "com.dockistrate.state-dir=$state_label" --label "com.dockistrate.backend-domain=$domain" \
      --label "com.dockistrate.backend-launch=$token" nginx:alpine)"
    _backend_identity_store "$domain" "$ID" "$token"
    state_backend_ports_row_backend "$domain" 10.0.0.5:80 dockistrate-net >>"$BACKEND_PORTS_FILE"
  }
  function assert_saved_proof() {
    _backend_identity_read "$1" || fail 'recovery did not leave a valid saved identity'
    [ "$BACKEND_IDENTITY_ID" = "$2" ] && [ "$BACKEND_IDENTITY_TOKEN" = "$3" ] || fail 'recovery saved a different ID or token'
  }
  function assert_recovery_retained() {
    [ "${CLEANUP_RUNTIME_DELETE_COUNT:-0}" -gt 0 ] || fail 'failed recovery discarded staged proof'
    [ "${CLEANUP_RUNTIME_DELETE_IDS[0]-}" = "$ID" ] || fail 'failed recovery changed the staged ID'
    [ "${CLEANUP_RUNTIME_DELETE_TOKENS[0]-}" = "$TOKEN" ] || fail 'failed recovery changed the staged token'
    [ "${CLEANUP_RUNTIME_DELETE_RECOVERY_BACKUP:-}" = "$original_backup" ] || fail 'failed recovery lost the original backup path'
    [ -f "$original_backup" ] || fail 'original cleanup backup was removed'
    grep -Fq "Original cleanup state remains in backup: $original_backup" "$FIXTURE/output" || fail 'failed proof recovery omitted the original backup diagnostic'
  }
  seed_recovery_backend "$DOMAIN" "$TOKEN"
  local first_id="$ID"
  case "$variant" in
  partial_delete | mid_write_failure)
    seed_recovery_backend "$second_domain" "$second_token"
    second_id="$ID"
    ID="$first_id"
    ;;
  esac
  eval "$(declare -f backup_files_only | sed '1s/backup_files_only/recovery_real_backup_files_only/')"
  eval "$(declare -f _backend_identity_store | sed '1s/_backend_identity_store/recovery_real_identity_store/')"
  eval "$(declare -f remove_container_and_anonymous_volumes | sed '1s/remove_container_and_anonymous_volumes/recovery_real_remove/')"

  case "$variant" in
  original_commit_clean | original_commit_uninstall)
    cp "$BACKEND_IDENTITY_FILE" "$FIXTURE/identity.before"
    cp "$BACKEND_PORTS_FILE" "$FIXTURE/ports.before"
    function backup_files_only() {
      case "${1:-}" in post_clean_all_* | post_uninstall_all_*) return 1 ;; esac
      recovery_real_backup_files_only "$@"
    }
    : >"$DOCKER_MOCK_LOG_FILE"
    if [ "$variant" = original_commit_clean ]; then
      if clean_all "$DOMAIN" >"$FIXTURE/output" 2>&1; then fail 'failed original commit returned success'; fi
    else
      if uninstall_all --scope backend >"$FIXTURE/output" 2>&1; then fail 'failed original commit returned success'; fi
    fi
    cmp -s "$FIXTURE/identity.before" "$BACKEND_IDENTITY_FILE" || fail 'original commit failure lost identity state'
    cmp -s "$FIXTURE/ports.before" "$BACKEND_PORTS_FILE" || fail 'original commit failure lost backend state'
    [ "$(docker inspect -f '{{.Id}}' "$CNAME")" = "$ID" ] || fail 'original commit failure did not restore the staged ID'
    [ "$(docker inspect -f '{{.State.Status}}' "$ID")" = running ] || fail 'original commit failure did not restore running state'
    if grep -Eq '^subcommand=rm ' "$DOCKER_MOCK_LOG_FILE"; then fail 'conditional command finalized runtime after its commit failed'; fi
    printf '[PASS] %s stops before final removal when the original commit returns failure\n' "$variant"
    return 0
    ;;
  command_clean | command_config | command_all)
    function remove_container_and_anonymous_volumes() { return 1; }
    if [ "$variant" = command_clean ]; then
      if clean_all "$DOMAIN" >"$FIXTURE/output" 2>&1; then fail 'failed cleanup removal returned success'; fi
    else
      if uninstall_all --scope "${variant#command_}" >"$FIXTURE/output" 2>&1; then fail 'failed uninstall removal returned success'; fi
    fi
    assert_saved_proof "$DOMAIN" "$ID" "$TOKEN"
    [ "$(docker inspect -f '{{.Id}}' "$CNAME")" = "$ID" ] || fail 'failed cleanup did not restore the exact original'
    [ "$(docker inspect -f '{{.State.Status}}' "$ID")" = running ] || fail 'failed cleanup did not restart the original'
    [ -s "$LAST_POST_BACKUP_FILE" ] || fail 'recovery did not commit a real return transaction'
    if backend_exists "$DOMAIN"; then fail 'identity recovery unexpectedly restored deleted routing'; fi
    [ "${CLEANUP_RUNTIME_DELETE_COUNT:-0}" -eq 0 ] || fail 'successful recovery retained stale staged state'
    printf '[PASS] %s persists ownership after post-commit removal failure\n' "$variant"
    return 0
    ;;
  esac

  begin_transaction_return original_cleanup "$CONFIG_DIR" || fail 'cannot begin the original transaction'
  original_backup="$PRE_CHANGE_BACKUP"
  _cleanup_runtime_stage_container_delete "$CNAME" "$DOMAIN" "$ID" "$TOKEN" || fail 'cannot stage the original ID'
  if [ -n "$second_id" ]; then
    _cleanup_runtime_stage_container_delete "backend-$second_domain" "$second_domain" "$second_id" "$second_token" || fail 'cannot stage the second ID'
  fi
  rm -f "$BACKEND_IDENTITY_FILE"
  if [ "$variant" = active_original ]; then
    if _cleanup_runtime_preserve_backend_identities_from_index 0 >"$FIXTURE/output" 2>&1; then fail 'proof recovery ran before the original transaction committed'; fi
    [ ! -e "$BACKEND_IDENTITY_FILE" ] || fail 'active transaction guard wrote proof'
    [ "$PRE_CHANGE_BACKUP" = "$original_backup" ] && [ "$TRANSACTION_DEPTH" -eq 1 ] || fail 'active transaction guard altered the original transaction'
    [ "${CLEANUP_RUNTIME_DELETE_IDS[0]-}" = "$ID" ] || fail 'active transaction guard lost recovery proof'
    transaction_return_failure >"$FIXTURE/output" 2>&1 || true
    assert_saved_proof "$DOMAIN" "$ID" "$TOKEN"
    printf '[PASS] identity recovery refuses writes while the original transaction is active\n'
    return 0
  fi
  end_transaction_success || fail 'cannot commit the original cleanup transaction'
  function remove_container_and_anonymous_volumes() { return 1; }
  case "$variant" in
  rename_failure | start_failure)
    function docker() {
      if [ "$variant" = rename_failure ] && [ "${1:-}" = rename ] && [ "${2:-}" = "$ID" ]; then return 1; fi
      if [ "$variant" = start_failure ] && [ "${1:-}" = start ] && [ "${2:-}" = "$ID" ]; then return 1; fi
      command docker "$@"
    }
    ;;
  partial_delete)
    function remove_container_and_anonymous_volumes() {
      [ "${1:-}" != "$second_id" ] || return 1
      recovery_real_remove "$@"
    }
    ;;
  matching_identity) _backend_identity_store "$DOMAIN" "$ID" "$TOKEN" ;;
  conflict_id) _backend_identity_store "$DOMAIN" "$(printf '%064d' 999)" "$TOKEN" ;;
  conflict_token) _backend_identity_store "$DOMAIN" "$ID" "$second_token" ;;
  malformed) printf 'domain,container_id,ownership_token\n%s,bad-id,%s\n' "$DOMAIN" "$TOKEN" >"$BACKEND_IDENTITY_FILE" ;;
  duplicate)
    _backend_identity_store "$DOMAIN" "$ID" "$TOKEN"
    printf '%s,%s,%s\n' "$DOMAIN" "$ID" "$TOKEN" >>"$BACKEND_IDENTITY_FILE"
    ;;
  begin_refusal) function begin_transaction_return() { return 1; } ;;
  mid_write_failure)
    function _backend_identity_store() {
      [ "${1:-}" != "$second_domain" ] || return 1
      recovery_real_identity_store "$@"
    }
    ;;
  commit_failure)
    function backup_files_only() {
      [ "${1:-}" != post_cleanup_backend_identity_recovery ] || return 1
      recovery_real_backup_files_only "$@"
    }
    ;;
  esac
  if [ -f "$BACKEND_IDENTITY_FILE" ]; then cp "$BACKEND_IDENTITY_FILE" "$FIXTURE/identity.before"; fi
  : >"$DOCKER_MOCK_LOG_FILE"
  if _cleanup_runtime_finalize_staged_deletes >"$FIXTURE/output" 2>&1; then fail 'failed final removal returned success'; fi
  case "$variant" in
  conflict_id | conflict_token | malformed | duplicate)
    cmp -s "$FIXTURE/identity.before" "$BACKEND_IDENTITY_FILE" || fail 'proof recovery overwrote concurrent or invalid state'
    assert_recovery_retained
    ;;
  begin_refusal | mid_write_failure | commit_failure)
    [ ! -e "$BACKEND_IDENTITY_FILE" ] || fail 'failed proof transaction left a partial identity write'
    assert_recovery_retained
    ;;
  partial_delete)
    if docker inspect -f '{{.Id}}' "$ID" >/dev/null 2>&1; then fail 'earlier successful deletion was undone'; fi
    _backend_identity_read "$DOMAIN" true || fail 'recovered sidecar is invalid'
    [ "$BACKEND_IDENTITY_FOUND" -eq 0 ] || fail 'recovery reintroduced proof for an already deleted ID'
    assert_saved_proof "$second_domain" "$second_id" "$second_token"
    [ "$(docker inspect -f '{{.State.Status}}' "$second_id")" = running ] || fail 'remaining original was not restored'
    ;;
  *)
    assert_saved_proof "$DOMAIN" "$ID" "$TOKEN"
    if [ "$variant" = rename_failure ] || [ "$variant" = start_failure ]; then
      [ "${CLEANUP_RUNTIME_DELETE_IDS[0]-}" = "$ID" ] || fail 'incomplete runtime recovery discarded staged proof'
      [ "$(docker inspect -f '{{.State.Status}}' "$ID")" = exited ] || fail 'incomplete recovery unexpectedly restarted the original'
    else
      [ "${CLEANUP_RUNTIME_DELETE_COUNT:-0}" -eq 0 ] || fail 'complete recovery retained stale staged state'
    fi
    ;;
  esac
  if transaction_is_active; then fail 'recovery left a transaction active'; fi
  printf '[PASS] post-commit identity recovery handles %s without losing ownership proof\n' "$variant"
)

for recovery_case in command_clean command_config command_all rename_failure start_failure partial_delete matching_identity \
  conflict_id conflict_token malformed duplicate begin_refusal mid_write_failure commit_failure active_original \
  original_commit_clean original_commit_uninstall; do
  run_recovery_case "$recovery_case"
done

printf '%s\n' 'Backend cleanup recovery identity checks passed.'
