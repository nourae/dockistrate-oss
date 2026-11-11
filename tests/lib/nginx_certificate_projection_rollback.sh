# shellcheck shell=bash

function assert_mounted_key_access() {
  python3 - "$(cat "$MODEL/source")" "$SERVER_REF/privkey.pem" "$MODEL/original-key.json" "$MODEL/run.argv" <<'PY'
import hashlib,json,os,stat,sys
root,relative,receipt,arguments=sys.argv[1:]
expected=json.load(open(receipt))
args=open(arguments,'rb').read().split(b'\0')
user=args[args.index(b'--user')+1].decode()
assert user==expected['container_user'], 'Factory did not preserve configured container user'
uid,gid=map(int,user.split(':'))
fd=os.open(root,os.O_RDONLY|os.O_DIRECTORY)
info=os.stat(relative,dir_fd=fd)
actual=dict(uid=info.st_uid,gid=info.st_gid,mode=stat.S_IMODE(info.st_mode))
assert actual==expected['metadata'], 'Mounted key metadata changed: expected %r, found %r' % (expected['metadata'],actual)
# Simulate access from the container bind root, not traversal of host-only
# state parents. Root runs exercise an actual foreign mapped UID/GID.
if os.geteuid()==0:
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
key=os.open(relative,os.O_RDONLY,dir_fd=fd)
with os.fdopen(key,'rb') as stream:
    assert hashlib.sha256(stream.read()).hexdigest()==expected['sha256'], 'Mounted key bytes changed'
os.close(fd)
PY
}

function test_projection_rollback() {
  local test_case="$1" status=0
  if [ "$test_case" != reload_only_root_commit_failure ]; then set_mapped_key_owner; fi
  setup_projection_runtime
  NGINX_DOCKER_OPTS="--user $(python3 - "$SERVER_DIR/privkey.pem" <<'PY'
import os,sys
info=os.stat(sys.argv[1]); print('%s:%s' % (info.st_uid,info.st_gid))
PY
)"
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  update_nginx_config >"$TMP_ROOT/runtime-first.log" 2>&1 || { cat "$TMP_ROOT/runtime-first.log" >&2; fail_test 'Initial update failed'; }
  require_runtime_projection
  python3 - "$SERVER_DIR/privkey.pem" "$MODEL/original-key.json" <<'PY'
import hashlib,json,os,stat,sys
info=os.stat(sys.argv[1])
with open(sys.argv[2],'w') as out:
    json.dump(dict(metadata=dict(uid=info.st_uid,gid=info.st_gid,mode=stat.S_IMODE(info.st_mode)),sha256=hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest(),container_user='%s:%s' % (info.st_uid,info.st_gid)),out)
PY
  assert_mounted_key_access
  cp "$MODEL/effective-config" "$MODEL/original-config"
  cp "$BACKEND_PORTS_FILE" "$MODEL/original-ports"
  if [ "$test_case" = capture_dependency_failure_preserves_state ]; then
    : >"$MODEL/events"
    # The public helper starts a fresh Bash. Inject a real executable failure
    # through PATH rather than depending on inherited shell functions.
    PROJECTION_TEST_REAL_OPENSSL="$(type -P openssl)"
    PROJECTION_TEST_DEPENDENCY_MARKER="$MODEL/dependency-failure-reached"
    export PROJECTION_TEST_REAL_OPENSSL PROJECTION_TEST_DEPENDENCY_MARKER
    mkdir "$TMP_ROOT/dependency-bin"
    cat >"$TMP_ROOT/dependency-bin/openssl" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
if [ "${1:-}" = dgst ] && [ ! -f "$PROJECTION_TEST_DEPENDENCY_MARKER" ]; then
  : >"$PROJECTION_TEST_DEPENDENCY_MARKER"
  printf '[Error] Injected digest helper launch failure for projection capture\n' >&2
  exit 127
fi
exec "$PROJECTION_TEST_REAL_OPENSSL" "$@"
SH
    chmod 755 "$TMP_ROOT/dependency-bin/openssl"
    if PATH="$TMP_ROOT/dependency-bin:$PATH" begin_transaction_return "projection_capture_failure" "$CONFIG_DIR" >"$TMP_ROOT/runtime-failure.log" 2>&1; then
      fail_test 'Unavailable capture dependency allowed transaction to start'
    fi
    [ -f "$MODEL/dependency-failure-reached" ] || fail_test 'Dependency failure was not exercised'
    if transaction_is_active; then fail_test 'Failed transaction start remained active'; fi
    [ -z "${NGINX_RUNTIME_ROLLBACK_PROJECTION_STATE:-}" ] || fail_test 'Failed transaction start retained snapshot token'
    [ -z "${NGINX_RUNTIME_ROLLBACK_DEPTH:-}" ] || fail_test 'Failed transaction start retained runtime recovery state'
    case " ${ROLLBACK_PRE_HOOK:-} " in *' _nginx_runtime_rollback_if_needed '*) fail_test 'Failed transaction start retained runtime hook' ;; esac
    [ ! -e "$(_transaction_lock_dir)" ] || fail_test 'Failed transaction start leaked mutation lock'
    [ ! -s "$MODEL/events" ] || fail_test 'Failed transaction start changed proxy runtime'
    cmp -s "$NGINX_HTTP_CONF_DIR/backends.conf" "$MODEL/original-config" || fail_test 'Failed transaction start changed generated config'
    assert_mounted_key_access
    _nginx_verify_certificate_projection "$(cat "$MODEL/source")" || fail_test 'Failed transaction start damaged active snapshot'
    return 0
  fi
  case "$test_case" in
  stopped_before_update_failure) rm "$MODEL/running" ;;
  absent_before_update_failure) rm "$MODEL/exists" "$MODEL/running" ;;
  invalid_source_before_update_failure)
    rm "$SERVER_DIR/privkey.pem"
    ln -s "$OUTSIDE/sentinel" "$SERVER_DIR/privkey.pem"
    ;;
  esac
  : >"$MODEL/events"
  set +e
  (
    set -e
    begin_transaction "projection_rollback" "$CONFIG_DIR" "$OWNER_DIR"
    case "$test_case" in
    reload_only_commit_failure | reload_only_root_commit_failure | hup_reload_rollback | term_reload_rollback)
      printf '%s\n' '127.0.0.2:8000' >"$CONFIG_DIR/runtime-render-value"
      update_nginx_config
      grep -qx reload "$MODEL/events" || fail_test 'Unchanged projection did not take reload path'
      if grep -qx run "$MODEL/events"; then fail_test 'Unchanged projection unexpectedly recreated before commit'; fi
      if cmp -s "$MODEL/effective-config" "$MODEL/original-config"; then fail_test 'Reload fixture did not change effective config'; fi
      : >"$MODEL/injection-reached"
      case "$test_case" in
      hup_reload_rollback | term_reload_rollback)
        # Bash 3 keeps $$ from its parent in subshells. An external child's
        # PPID identifies this exact transaction process without signaling the
        # test runner. EXIT performs the real rollback while HUP/TERM unwinds.
        "$BASH" -c 'printf "%s\n" "$PPID"' >"$MODEL/signal-target"
        trap ': >"$MODEL/signal-handler-reached"; exit 129' HUP
        trap ': >"$MODEL/signal-handler-reached"; exit 143' TERM
        if [ "$test_case" = hup_reload_rollback ]; then
          kill -HUP "$(cat "$MODEL/signal-target")"
        else
          kill -TERM "$(cat "$MODEL/signal-target")"
        fi
        fail_test 'Injected signal did not leave the transaction'
        ;;
      esac
      : >"$MODEL/fail-commit"
      end_transaction_success
      ;;
    early_render_failure)
      printf 'invalid,row\n' >>"$BACKEND_PORTS_FILE"
      : >"$MODEL/injection-reached"
      update_nginx_config
      ;;
    early_projection_failure)
      printf 'invalid public CA material\n' >"$OWNER_DIR/ca.crt"
      : >"$MODEL/injection-reached"
      update_nginx_config
      ;;
    invalid_source_before_update_failure) : >"$MODEL/injection-reached"; update_nginx_config ;;
    before_update_failure | stopped_before_update_failure | absent_before_update_failure)
      printf '%s\n' 'failed transaction touched config' >"$CONFIG_DIR/failed-mutation"
      : >"$MODEL/injection-reached"
      false
      ;;
    *) fail_test 'Unknown rollback case' ;;
    esac
  ) >"$TMP_ROOT/runtime-failure.log" 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail_test 'Injected rollback failure unexpectedly succeeded'
  [ -f "$MODEL/injection-reached" ] || { cat "$TMP_ROOT/runtime-failure.log" >&2; fail_test 'Expected failure boundary was not reached'; }
  case "$test_case" in
  hup_reload_rollback | term_reload_rollback)
    [ -f "$MODEL/signal-handler-reached" ] || fail_test 'Signal handler was not reached'
    ;;
  esac
  grep -Fq 'Rolled back.' "$TMP_ROOT/runtime-failure.log" || { cat "$TMP_ROOT/runtime-failure.log" >&2; fail_test 'Rollback did not complete'; }
  cmp -s "$BACKEND_PORTS_FILE" "$MODEL/original-ports" || fail_test 'Rollback changed prior backend state'
  cmp -s "$NGINX_HTTP_CONF_DIR/backends.conf" "$MODEL/original-config" || fail_test 'Rollback changed prior generated config'
  [ ! -e "$CONFIG_DIR/failed-mutation" ] || fail_test 'Rollback retained failed mutation'
  [ ! -e "$(_transaction_lock_dir)" ] || fail_test 'Rollback leaked mutation lock'
  case "$test_case" in
  absent_before_update_failure)
    [ ! -f "$MODEL/exists" ] && [ ! -f "$MODEL/running" ] || fail_test 'Rollback created previously absent proxy'
    ;;
  *)
    [ -f "$MODEL/exists" ] || fail_test 'Rollback lost original proxy'
    if [ "$test_case" = stopped_before_update_failure ]; then
      [ ! -f "$MODEL/running" ] || fail_test 'Rollback started previously stopped proxy'
    else
      [ -f "$MODEL/running" ] || fail_test 'Rollback stopped original proxy'
    fi
    assert_mounted_key_access
    _nginx_verify_certificate_projection "$(cat "$MODEL/source")" || fail_test 'Rollback left invalid mounted snapshot'
    cmp -s "$MODEL/effective-config" "$MODEL/original-config" || fail_test 'Rollback left changed effective proxy config'
    ;;
  esac
  if [ "$test_case" = invalid_source_before_update_failure ]; then
    [ -L "$SERVER_DIR/privkey.pem" ] || fail_test 'Recovery changed invalid authoritative input outside transaction'
    [ "$(cat "$OUTSIDE/sentinel")" = 'foreign sentinel' ] || fail_test 'Recovery touched foreign material'
  fi
}
