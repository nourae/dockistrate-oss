#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=lib/backends.sh
source "$ROOT_DIR/lib/backends.sh"
# shellcheck source=tests/lib/backend_identity_fixture.sh
source "$ROOT_DIR/tests/lib/backend_identity_fixture.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_backend_failed_start.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
ORIGINAL_ID="$(printf '%064d' 1)"
LAUNCHED_ID="$(printf '%064d' 2)"
FOREIGN_ID="$(printf '%064d' 3)"
LAUNCH_LABEL="com.dockistrate.backend-launch"
ORIGINAL_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CNAME="backend-example.com"

function fail() { echo "[Error] ${CASE}: $*" >&2; exit 1; }
function require_log() { grep -Fq -- "$1" "$MOCK_LOG" || fail "missing Docker operation: $1"; }
function reject_log() { if grep -Fq -- "$1" "$MOCK_LOG"; then fail "unexpected Docker operation: $1"; fi; }
function require_output() { grep -Fq -- "$1" "$CASE_DIR/output" || { cat "$CASE_DIR/output" >&2; fail "missing output: $1"; }; }

# The mock records immutable IDs separately from names, including Created-state
# containers which Docker can leave behind after run exits with an error.
function mock_write() {
  printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >"$MOCK_DIR/$1"
}
function mock_resolve() {
  local target="${1:-}" file="" id="" name="" status="" token=""
  for file in "$MOCK_DIR"/*; do
    [ -f "$file" ] || continue
    IFS='|' read -r id name status token <"$file"
    if [ "$target" = "$id" ] || [ "$target" = "$name" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done
  return 1
}
function container_exists() { mock_resolve "${1:-}" >/dev/null; }
function container_running() {
  local file="" id="" name="" status="" token=""
  file="$(mock_resolve "${1:-}")" || return 1
  IFS='|' read -r id name status token <"$file"
  [ "$status" = running ]
}
function docker() {
  printf '%s\n' "$*" >>"$MOCK_LOG"
  local command="${1:-}" file="" id="" name="" status="" token="" target="" format=""
  shift || true
  case "$command" in
  run)
    local cidfile="" label="" labels=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --name) name="$2"; shift 2 ;;
      --label)
        label="$2"
        labels+="$label"$'\n'
        case "$label" in "$LAUNCH_LABEL="*) token="${label#*=}" ;; esac
        shift 2 ;;
      --label-file)
        labels+="$(cat "$2")"$'\n'
        shift 2 ;;
      --cidfile) cidfile="$2"; shift 2 ;;
      --cidfile=*) cidfile="${1#*=}"; shift ;;
      *) shift ;;
      esac
    done
    if container_exists "$name"; then
      echo 'mock Docker: name already in use' >&2
      return 125
    fi
    [ -z "$cidfile" ] || printf '%s\n' "$LAUNCHED_ID" >"$cidfile"
    mock_write "$LAUNCHED_ID" "$name" created "$token"
    printf '%s' "$labels" >"$CASE_DIR/$LAUNCHED_ID.labels"
    case "$CASE" in
    add_signal_failure|update_signal_failure) kill -TERM "$(cat "$CASE_DIR/command.pid")"; return 125 ;;
    add_hup_failure) kill -HUP "$(cat "$CASE_DIR/command.pid")"; return 125 ;;
    add_int_failure) kill -INT "$(cat "$CASE_DIR/command.pid")"; return 125 ;;
    *commit*|*success*|*config*)
      mock_write "$LAUNCHED_ID" "$name" running "$token"
      printf '%s\n' "$LAUNCHED_ID"
      return 0 ;;
    *concurrent*)
      # The just-created object is moved aside while a different object claims
      # the canonical name. Name-based cleanup would delete the wrong object.
      mock_write "$LAUNCHED_ID" "${name}-moved" created "$token"
      mock_write "$FOREIGN_ID" "$name" running unrelated
      ;;
    esac
    echo 'mock Docker: start failed after container creation' >&2
    return 125
    ;;
  ps)
    local filter="" include_all=false no_trunc=false
    while [ "$#" -gt 0 ]; do
      case "$1" in
      --filter) filter="$2"; shift 2 ;;
      -a|--all) include_all=true; shift ;;
      --no-trunc) no_trunc=true; shift ;;
      *) shift ;;
      esac
    done
    [ "$CASE" != add_enumeration_failure ] || return 1
    for file in "$MOCK_DIR"/*; do
      [ -f "$file" ] || continue
      IFS='|' read -r id name status token <"$file"
      if [ "$include_all" != true ] && [ "$status" != running ]; then continue; fi
      if [ "$filter" = "label=$LAUNCH_LABEL=$token" ] || [ "$filter" = "id=$id" ]; then
        [ "$no_trunc" = true ] || id="${id:0:12}"
        printf '%s\n' "$id"
      fi
    done
    ;;
  inspect)
    [ "${1:-}" = -f ] || return 1
    format="$2"; target="$3"
    file="$(mock_resolve "$target")" || return 1
    IFS='|' read -r id name status token <"$file"
    case "$format" in
    *'}}verified{{else}}unverified{{end}}'*)
      if [ "$CASE" = add_label_mismatch ]; then printf 'unverified\n'; return 0; fi
      backend_fixture_snapshot "$format" "$id" "$status" "$CASE_DIR/$id.labels"
      ;;
    *'.Config.Labels'*)
      if [ "$CASE" = add_label_mismatch ]; then token=unrelated; fi
      printf '%s %s\n' "$id" "$token" ;;
    *'.State.Status'*) printf '%s\n' "$status" ;;
    *'.Config.Image'*) printf 'nginx:alpine\n' ;;
    *'.Id'*) printf '%s\n' "$id" ;;
    *) return 1 ;;
    esac
    ;;
  rename|stop|start|rm)
    target="${@: -1}"
    [ "$command" != rename ] || target="$1"
    file="$(mock_resolve "$target")" || return 1
    IFS='|' read -r id name status token <"$file"
    case "$command" in
    rename)
      if container_exists "$2"; then return 1; fi
      mock_write "$id" "$2" "$status" "$token"
      case "$CASE:$2" in update_rename_failure:"$CNAME"-rollback-*) return 1 ;; esac
      ;;
    stop)
      mock_write "$id" "$name" exited "$token"
      [ "$CASE" != update_stop_failure ] || return 1
      ;;
    start)
      [ "$CASE" != update_restart_failure ] || return 1
      mock_write "$id" "$name" running "$token" ;;
    rm)
      [ "$CASE" != add_cleanup_failure ] || return 1
      rm -f "$file" ;;
    esac
    ;;
  *) echo "Unexpected Docker command: $command $*" >&2; return 1 ;;
  esac
}

# External launch failures exercise inherited ERR handling inside Docker stdout
# captures, which Bash 3 treats differently from a shell-function mock.
BACKEND_IDENTITY_FIXTURE_FILE="$ROOT_DIR/tests/lib/backend_identity_fixture.sh"
mkdir -p "$TMP_ROOT/bin"
printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'source "$BACKEND_IDENTITY_FIXTURE_FILE"' >"$TMP_ROOT/bin/docker"
for mock_function in mock_write mock_resolve container_exists container_running docker; do
  declare -f "$mock_function" >>"$TMP_ROOT/bin/docker"
done
printf '\ndocker "$@"\n' >>"$TMP_ROOT/bin/docker"
chmod +x "$TMP_ROOT/bin/docker"

ORIGINAL_ROLLBACK_DEF="$(declare -f _rollback_handler_common | sed '1s/_rollback_handler_common/original_rollback_handler_common/')"
eval "$ORIGINAL_ROLLBACK_DEF"
function _rollback_handler_common() {
  case "$CASE" in
  *_external_start_failure) sh -c 'printf "%s\n" "$PPID"' >>"$CASE_DIR/rollback.pids" ;;
  esac
  original_rollback_handler_common "$@"
}

# Keep validation, state writes, snapshot/restore, transaction hooks and commit
# finalization real. Only unrelated proxy/network work and logging are stubbed.
function ensure_network_exists() { :; }
function get_container_network_ip() { printf '172.30.0.99\n'; }
function update_nginx_config() { [ "$CASE" != add_config_failure ]; }
function log_msg() { :; }
function capture_docker_logs() { :; }
function load_config() { :; }

ORIGINAL_BACKUP_DEF="$(declare -f backup_files_only | sed '1s/backup_files_only/original_backup_files_only/')"
eval "$ORIGINAL_BACKUP_DEF"
function backup_files_only() {
  case "$CASE:${1:-}" in
  *commit_signal*:post_*)
    original_backup_files_only "$@" || return 1
    kill -TERM "$(cat "$CASE_DIR/command.pid")"
    return 0 ;;
  *commit*:post_*) return 1 ;;
  esac
  original_backup_files_only "$@"
}

function prepare_case() {
  local original_status=""
  CASE="$1"
  CASE_DIR="$TMP_ROOT/$CASE"
  MOCK_DIR="$CASE_DIR/containers"
  MOCK_LOG="$CASE_DIR/docker.log"
  BASE_DIR="$CASE_DIR"
  STATE_DIR="$BASE_DIR/state"
  CONFIG_DIR="$STATE_DIR/config"
  CERTS_DIR="$STATE_DIR/certs"
  LOG_DIR="$STATE_DIR/logs"
  ERROR_LOG_DIR="$LOG_DIR/errors"
  TMP_DIR="$STATE_DIR/tmp"
  BACKUP_DIR="$STATE_DIR/backups"
  BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
  BACKEND_IDENTITY_FILE="$CONFIG_DIR/backend_identity.csv"
  BACKEND_DOCKER_OPTS_FILE="$CONFIG_DIR/backend_docker_opts.csv"
  LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
  CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha1"
  INTERACTIVE=false
  SKIP_DOCKER_CHECKS=false
  mkdir -p "$MOCK_DIR" "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR" "$BACKUP_DIR" "$ERROR_LOG_DIR"
  : >"$MOCK_LOG"
  printf '%s\n' "$LAUNCH_LABEL=operator-value" >"$CASE_DIR/operator.labels"
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  printf '%s\n' "$STATE_BACKEND_DOCKER_OPTS_HEADER" >"$BACKEND_DOCKER_OPTS_FILE"
  case "$CASE" in
  update_*)
    state_backend_ports_row_backend example.com 10.0.0.5:8000 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
    if [ "$CASE" = update_missing_start_failure ]; then
      _backend_identity_store example.com "$ORIGINAL_ID" "$ORIGINAL_TOKEN"
    else
      original_status=running
      [ "$CASE" != update_stopped_start_failure ] || original_status=exited
      mock_write "$ORIGINAL_ID" "$CNAME" "$original_status" "$ORIGINAL_TOKEN"
      backend_fixture_seed_labels "$CASE_DIR/$ORIGINAL_ID.labels" "$ORIGINAL_TOKEN" example.com "$STATE_DIR"
      _backend_identity_store example.com "$ORIGINAL_ID" "$ORIGINAL_TOKEN"
    fi
    ;;
  add_preexisting) mock_write "$FOREIGN_ID" "$CNAME" running unrelated ;;
  esac
  cp "$BACKEND_PORTS_FILE" "$CASE_DIR/ports.before"
  cp "$BACKEND_DOCKER_OPTS_FILE" "$CASE_DIR/options.before"
  if [ -f "$BACKEND_IDENTITY_FILE" ]; then cp "$BACKEND_IDENTITY_FILE" "$CASE_DIR/identity.before"; fi
}

function invoke_case() {
  # Run outside a conditional, so ERR traps and errexit behave like the CLI.
  # The parent captures its status after this subshell has exited.
  set -Eeuo pipefail
  # A direct child exposes this invoking shell's PID on Bash 3 as well as 5;
  # $$ would still identify the parent of this subshell.
  sh -c 'printf "%s\n" "$PPID"' >"$CASE_DIR/command.pid"
  case "$CASE" in
  *_external_start_failure)
    unset -f docker
    PATH="$TMP_ROOT/bin:$PATH"
    export PATH BACKEND_IDENTITY_FIXTURE_FILE CASE CASE_DIR MOCK_DIR MOCK_LOG CNAME ORIGINAL_ID LAUNCHED_ID FOREIGN_ID LAUNCH_LABEL
    ;;
  esac
  case "$CASE" in
  add_success_custom_traps) trap ': original TERM handler' TERM ;;
  add_success_ignored_traps) trap '' HUP INT TERM ;;
  esac
  trap -p HUP INT TERM >"$CASE_DIR/traps.before"
  case "$CASE" in
  update_cidfile_failure) update_backend example.com --image nginx:alpine --docker-opts "--cidfile '$CASE_DIR/operator.cid' --label-file '$CASE_DIR/operator.labels'" ;;
  update_*) update_backend example.com --image nginx:alpine ;;
  add_cidfile*) add_backend example.com nginx:alpine 8000 http --no-expose --docker-opts "--cidfile '$CASE_DIR/operator.cid' --label-file '$CASE_DIR/operator.labels'" ;;
  add_interactive*)
    INTERACTIVE=true
    add_backend example.com nginx:alpine 8000 http 80 none no '' "$DEFAULT_NETWORK" no ;;
  *) add_backend example.com nginx:alpine 8000 http --no-expose ;;
  esac
  trap -p HUP INT TERM >"$CASE_DIR/traps.after"
  [ "${BACKEND_RUNTIME_SIGNAL_TRAPS_ACTIVE:-false}" = false ] || fail 'successful command retained signal rollback state'
}

function check_case() {
  local status="$1" id="" name="" state="" token=""
  if [[ "$CASE" = add_success* ]]; then
    [ "$status" -eq 0 ] || { cat "$CASE_DIR/output" >&2; fail 'successful launch failed'; }
    [ -f "$MOCK_DIR/$LAUNCHED_ID" ] || fail 'committed container was deleted'
    reject_log 'rm '
    cmp -s "$CASE_DIR/traps.before" "$CASE_DIR/traps.after" || fail 'successful command changed caller signal handlers'
    return 0
  fi
  [ "$status" -ne 0 ] || fail 'failed operation unexpectedly succeeded'
  case "$CASE" in
  *_external_start_failure)
    [ -f "$CASE_DIR/rollback.pids" ] || fail 'external Docker failure never reached real transaction rollback'
    [ "$(wc -l <"$CASE_DIR/rollback.pids")" -eq 1 ] || fail 'external Docker failure triggered rollback more than once'
    cmp -s "$CASE_DIR/command.pid" "$CASE_DIR/rollback.pids" || fail 'rollback ran inside Docker command substitution instead of the invoking shell'
    ;;
  esac
  case "$CASE" in
  *signal_failure) [ "$status" -eq 143 ] || fail "TERM exit status was $status instead of 143" ;;
  add_hup_failure) [ "$status" -eq 129 ] || fail "HUP exit status was $status instead of 129" ;;
  add_int_failure) [ "$status" -eq 130 ] || fail "INT exit status was $status instead of 130" ;;
  esac
  cmp -s "$BACKEND_PORTS_FILE" "$CASE_DIR/ports.before" || fail 'backend state was not restored'
  cmp -s "$BACKEND_DOCKER_OPTS_FILE" "$CASE_DIR/options.before" || fail 'Docker options were not restored'
  if [ -f "$CASE_DIR/identity.before" ]; then
    cmp -s "$BACKEND_IDENTITY_FILE" "$CASE_DIR/identity.before" || fail 'ownership identity was not restored'
  elif [ -f "$BACKEND_IDENTITY_FILE" ] && [ "$(wc -l <"$BACKEND_IDENTITY_FILE")" -gt 1 ]; then
    fail 'failed add retained ownership identity'
  fi
  reject_log "rm -f -v $CNAME"
  reject_log "rm -f -v $FOREIGN_ID"
  reject_log "rm -f -v $ORIGINAL_ID"
  case "$CASE" in
  update_missing_start_failure|update_rename_failure|update_stop_failure)
    [ ! -f "$MOCK_DIR/$LAUNCHED_ID" ] || fail 'replacement was launched after staging failed'
    reject_log 'run '
    ;;
  add_preexisting)
    [ -f "$MOCK_DIR/$FOREIGN_ID" ] || fail 'preexisting container was deleted'
    reject_log 'rm '
    ;;
  add_cleanup_failure|add_enumeration_failure|add_label_mismatch)
    [ -f "$MOCK_DIR/$LAUNCHED_ID" ] || fail 'container unexpectedly removed after cleanup could not be proven'
    require_output 'Rollback failed or is incomplete'
    ;;
  *)
    [ ! -f "$MOCK_DIR/$LAUNCHED_ID" ] || fail 'transaction-owned container survived rollback'
    require_log "rm -f -v $LAUNCHED_ID"
    ;;
  esac
  case "$CASE" in
  *concurrent*)
    [ -f "$MOCK_DIR/$FOREIGN_ID" ] || fail 'concurrent replacement was deleted'
    IFS='|' read -r id name state token <"$MOCK_DIR/$FOREIGN_ID"
    [ "$name:$state" = "$CNAME:running" ] || fail 'concurrent replacement was altered'
    ;;
  esac
  case "$CASE" in
  update_missing_start_failure) : ;;
  update_*)
    [ -f "$MOCK_DIR/$ORIGINAL_ID" ] || fail 'original container was lost'
    IFS='|' read -r id name state token <"$MOCK_DIR/$ORIGINAL_ID"
    case "$CASE" in
    update_stopped_start_failure)
      [ "$name:$state" = "$CNAME:exited" ] || fail 'original stopped state was not preserved'
      reject_log 'start '
      require_output 'failed. Rolled back.' ;;
    update_rename_failure)
      [ "$name:$state" = "$CNAME:running" ] || fail 'mutating rename failure did not restore the original name'
      reject_log 'start '
      require_output 'failed. Rolled back.' ;;
    update_concurrent)
      case "$name" in "$CNAME"-rollback-*) : ;; *) fail 'original backup name changed after a collision' ;; esac
      [ "$state" = exited ] || fail 'blocked original recovery unexpectedly restarted the staged container'
      require_output 'Rollback failed or is incomplete' ;;
    update_restart_failure)
      [ "$name:$state" = "$CNAME:exited" ] || fail 'restart failure did not retain the restored original container'
      require_output 'Rollback failed or is incomplete' ;;
    *)
      [ "$name:$state" = "$CNAME:running" ] || fail 'original container was not restored running'
      require_log "start $ORIGINAL_ID"
      require_output 'failed. Rolled back.'
      ;;
    esac
    ;;
  esac
  case "$CASE" in *cidfile*) [ "$(cat "$CASE_DIR/operator.cid")" = "$LAUNCHED_ID" ] || fail 'operator cidfile was replaced or removed' ;; esac
}

cases='add_external_start_failure update_external_start_failure add_start_failure add_interactive_start_failure add_preexisting add_concurrent add_cidfile_failure add_cleanup_failure add_enumeration_failure add_label_mismatch add_config_failure add_commit_failure add_success update_start_failure update_missing_start_failure update_concurrent update_restart_failure update_commit_failure update_stopped_start_failure update_rename_failure update_stop_failure update_cidfile_failure add_signal_failure add_int_failure update_signal_failure add_commit_signal_failure update_commit_signal_failure add_success_custom_traps add_success_ignored_traps add_hup_failure'
case_group="${1:-}"
case "$case_group" in add|update) shift ;; *) exit 2 ;; esac
selected_cases=''
for case_name in $cases; do
  if [ "${case_name%%_*}" = "$case_group" ]; then selected_cases="$selected_cases $case_name"; fi
done
cases="$selected_cases"
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
  case " $cases " in *" $2 "*) cases="$2" ;; *) exit 2 ;; esac
fi
case_count=0
for case_name in $cases; do
  prepare_case "$case_name"
  set +e
  (invoke_case) >"$CASE_DIR/output" 2>&1
  case_status=$?
  set -e
  check_case "$case_status"
  printf '[PASS] %s\n' "$case_name"
  case_count=$((case_count + 1))
done
printf 'Backend %s cleanup: all %s lifecycle cases passed.\n' "$case_group" "$case_count"
