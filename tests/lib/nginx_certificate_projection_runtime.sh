# shellcheck shell=bash

# The real update, projection, container factory, transaction archives, and
# recovery hooks run here. Only Docker/network effects and unrelated render
# details are modeled. The model persists outside the transaction so a child
# failure cannot hide the runtime that rollback actually left behind.
function setup_projection_runtime() {
  MODEL="$TMP_ROOT/runtime-model"
  mkdir -p "$MODEL" "$LOG_DIR" "$ERROR_LOG_DIR" "$BACKUP_DIR" "$ACME_WEBROOT_DIR"
  SECURITY_IP_DIR="$NGINX_HTTP_CONF_DIR/security_ip"
  SECURITY_IP_STREAM_DIR="$NGINX_STREAM_CONF_DIR/security_ip"
  PATH_HEADER_DIR="$NGINX_HTTP_CONF_DIR/path_headers"
  mkdir -p "$SECURITY_IP_DIR" "$SECURITY_IP_STREAM_DIR" "$PATH_HEADER_DIR"
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" >"$BACKEND_ALIASES_FILE"
  SKIP_DOCKER_CHECKS=false
  NGINX_IMAGE=nginx:1.31.7
  NGINX_DOCKER_OPTS=''
  ENABLE_AUTO_BACKUPS=true
  _save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
  printf '%s\n' "$CERTS_DIR" >"$MODEL/source"
  : >"$MODEL/exists"
  : >"$MODEL/running"
  : >"$MODEL/labelled"
  : >"$MODEL/events"
  function log_msg() { :; }
  function capture_docker_logs() { :; }
  function build_security_rules_inc() { :; }
  function refresh_backend_networks() { :; }
  function refresh_backend_ips() { :; }
  function _build_header_files() { :; }
  function list_domain_aliases() { :; }
  function get_backend_http_version() { printf '%s\n' http1; }
  function _backend_header_identity_directives() { :; }
  function _sr_identity_directives() { :; }
  function _render_backend_upstream_for_domain() {
    if [ -f "$CONFIG_DIR/runtime-render-value" ]; then cat "$CONFIG_DIR/runtime-render-value"; else printf '%s\n' '127.0.0.1:8000'; fi
  }
  function get_backend_client_ip_header() { :; }
  function get_backend_proxy_ip_header() { :; }
  function get_proxy_http_version() { printf '%s\n' 1.1; }
  function get_port_tls_protocols() { printf '%s\n' TLSv1.2; }
  function get_port_tls_ciphers() { printf '%s\n' HIGH; }
  function fix_default_config() { :; }
  function create_nginx_config() { printf 'events {}\nhttp {}\n' >"$NGINX_CONFIG_DIR/nginx.conf"; }
  function get_all_mapped_port_bindings() { printf '%s\n' 443/tcp; }
  function container_published_port_bindings() { printf '%s\n' 443/tcp; }
  function container_exists() { [ -f "$MODEL/exists" ]; }
  function container_running() { [ -f "$MODEL/running" ]; }
  function ensure_network_exists() { :; }
  function assert_host_port_available_or_fail() { :; }
  function pull_image_if_autopull() { :; }
  function add_nginx_networks() { :; }
  function remove_unused_nginx_networks() { :; }
  function remove_container_and_anonymous_volumes() {
    printf '%s\n' remove >>"$MODEL/events"
    rm -f "$MODEL/exists" "$MODEL/running"
  }
  function docker() {
    local command="${1:-}" format="" arg="" source=""
    shift
    case "$command" in
    inspect)
      [ "${1:-}" = -f ] || return 93
      [ -f "$MODEL/exists" ] || return 1
      format="${2:-}"
      case "$format" in
      *'mount:%x:%t'*)
        printf 'mount:'
        printf '%s' "$(cat "$MODEL/source")" | _projection_hex
        printf ':false\ncomplete\n'
        ;;
      *'.Config.Labels'*)
        [ -f "$MODEL/labelled" ] || return 0
        case "$format" in
        *'com.dockistrate.managed'*) printf '%s\n' true ;;
        *'com.dockistrate.role'*) printf '%s\n' proxy ;;
        *'com.dockistrate.state-dir'*) printf '%s\n' "$STATE_DIR" ;;
        *) return 94 ;;
        esac
        ;;
      '{{json .Mounts}}')
        python3 - "$NGINX_CONFIG_DIR" "$NGINX_CONTAINER_CONF_ROOT" "$(cat "$MODEL/source")" "$ACME_WEBROOT_DIR" <<'PY'
import json,sys
print(json.dumps([dict(Type='bind',Source=source,Destination=target,RW=False) for source,target in
    [(sys.argv[1],sys.argv[2]),(sys.argv[3],'/etc/letsencrypt'),(sys.argv[4],'/var/www/certbot')]]))
PY
        ;;
      *'.Mounts'*)
        printf '%s|%s|false\n' "$NGINX_CONFIG_DIR" "$NGINX_CONTAINER_CONF_ROOT"
        printf '%s|/etc/letsencrypt|false\n' "$(cat "$MODEL/source")"
        printf '%s|/var/www/certbot|false\n' "$ACME_WEBROOT_DIR"
        ;;
      '{{.Config.Image}}') printf '%s\n' "$NGINX_IMAGE" ;;
      *) printf '[Error] Unexpected Docker inspection: %s\n' "$format" >&2; return 95 ;;
      esac
      ;;
    run)
      printf '%s\n' run >>"$MODEL/events"
      printf '%s\0' "$@" >"$MODEL/run.argv"
      if [ -f "$MODEL/fail-next-run" ]; then rm "$MODEL/fail-next-run"; return 37; fi
      while [ "$#" -gt 0 ]; do
        arg="$1"
        shift
        if [ "$arg" = -v ]; then
          [ "$#" -gt 0 ] || return 96
          case "$1" in *:/etc/letsencrypt:ro) source="${1%:/etc/letsencrypt:ro}" ;; esac
          shift
        fi
      done
      [ -n "$source" ] || return 97
      printf '%s\n' "$source" >"$MODEL/source"
      : >"$MODEL/exists"
      : >"$MODEL/running"
      : >"$MODEL/labelled"
      cp "$NGINX_HTTP_CONF_DIR/backends.conf" "$MODEL/effective-config"
      ;;
    exec)
      case "$*" in *'nginx -s reload'*) printf '%s\n' reload >>"$MODEL/events"; cp "$NGINX_HTTP_CONF_DIR/backends.conf" "$MODEL/effective-config" ;; *) printf '%s\n' config-check >>"$MODEL/events" ;; esac
      ;;
    stop) rm -f "$MODEL/running" ;;
    *) printf '[Error] Unexpected modeled Docker command: %s\n' "$command" >&2; return 98 ;;
    esac
  }
  eval "$(declare -f finalize_temp_file | sed '1s/finalize_temp_file/_projection_test_finalize_temp_file/')"
  function finalize_temp_file() {
    if [ -f "$MODEL/fail-commit" ] && [ "$1" = "$LAST_POST_BACKUP_FILE" ]; then
      rm "$MODEL/fail-commit"
      return 1
    fi
    _projection_test_finalize_temp_file "$@"
  }
  create_nginx_config
}

function require_runtime_projection() {
  PROJECTION="$(cat "$MODEL/source")"
  [ "$PROJECTION" != "$CERTS_DIR" ] || fail_test 'Running proxy retained broad issuer directory mount'
  [ -f "$MODEL/running" ] || fail_test 'Running proxy was lost'
  assert_default_allowlist
}

function test_projection_runtime() {
  local test_case="$1" original="" status=0
  case "$test_case" in
  launch_failure_restores_material_and_runtime | outer_commit_failure_restores_material_and_runtime) set_mapped_key_owner ;;
  esac
  setup_projection_runtime
  if [ "$test_case" = source_rotation_between_prepare_and_launch ]; then
    cp "$OWNER_DIR/ca.crl" "$TMP_ROOT/selected-crl"
    eval "$(declare -f _nginx_prepare_runtime_rollback | sed '1s/_nginx_prepare_runtime_rollback/_projection_test_prepare_runtime_rollback/')"
    function _nginx_prepare_runtime_rollback() {
      _projection_test_prepare_runtime_rollback "$@" || return 1
      rotate "$OWNER_DIR/ca.crl" $'-----BEGIN X509 CRL-----\nY2hhbmdlZC1hZnRlci1wcmVwYXJl\n-----END X509 CRL-----'
    }
  fi
  if [ "$test_case" = legacy_unlabelled_runtime_upgrades ]; then rm "$MODEL/labelled"; fi
  nginx_container_is_managed || fail_test 'Owned old proxy was not recognized for safe replacement'
  update_nginx_config >"$TMP_ROOT/runtime-first.log" 2>&1 || {
    cat "$TMP_ROOT/runtime-first.log" >&2
    fail_test 'Initial update failed'
  }
  if [ "$test_case" = source_rotation_between_prepare_and_launch ]; then
    PROJECTION="$(cat "$MODEL/source")"
    [ "$PROJECTION" != "$CERTS_DIR" ] && [ -d "$PROJECTION" ] || fail_test 'Selected generation was not mounted or was pruned'
    [ -f "$MODEL/running" ] || fail_test 'Selected generation did not leave a running proxy'
    cmp -s "$TMP_ROOT/selected-crl" "$PROJECTION/mtls/owner.example.test/ca.crl" || fail_test 'Factory rebuilt different material after initial preparation'
    if cmp -s "$OWNER_DIR/ca.crl" "$PROJECTION/mtls/owner.example.test/ca.crl"; then fail_test 'Source-rotation injection did not run'; fi
    _nginx_verify_certificate_projection "$PROJECTION" || fail_test 'Mounted selected generation was damaged by retirement'
    return 0
  fi
  require_runtime_projection
  [ "$(awk '$0 == "run" { n++ } END { print n+0 }' "$MODEL/events")" = 1 ] || fail_test 'Old proxy was not replaced exactly once'
  case "$test_case" in legacy_labelled_runtime_upgrades | legacy_unlabelled_runtime_upgrades) return 0 ;; esac
  original="$PROJECTION"
  : >"$MODEL/events"
  case "$test_case" in
  unchanged_runtime_reloads)
    update_nginx_config >"$TMP_ROOT/runtime-second.log" 2>&1 || { cat "$TMP_ROOT/runtime-second.log" >&2; fail_test 'Unchanged update failed'; }
    require_runtime_projection
    [ "$PROJECTION" = "$original" ] || fail_test 'Unchanged material selected a different source'
    grep -qx reload "$MODEL/events" || fail_test 'Unchanged runtime was not reloaded'
    if grep -qx run "$MODEL/events"; then fail_test 'Unchanged material unnecessarily replaced proxy'; fi
    ;;
  rotated_crl_recreates_runtime)
    rotate "$OWNER_DIR/ca.crl" $'-----BEGIN X509 CRL-----\nb3duZXItY3JsLXYy\n-----END X509 CRL-----'
    update_nginx_config >"$TMP_ROOT/runtime-second.log" 2>&1 || { cat "$TMP_ROOT/runtime-second.log" >&2; fail_test 'CRL rotation update failed'; }
    require_runtime_projection
    [ "$PROJECTION" != "$original" ] || fail_test 'Rotated CRL retained old mounted generation'
    [ "$(awk '$0 == "run" { n++ } END { print n+0 }' "$MODEL/events")" = 1 ] || fail_test 'CRL rotation did not replace proxy once'
    ;;
  launch_failure_restores_material_and_runtime | outer_commit_failure_restores_material_and_runtime)
    cp "$OWNER_DIR/ca.crl" "$TMP_ROOT/original-crl"
    cp "$NGINX_HTTP_CONF_DIR/backends.conf" "$TMP_ROOT/original-config"
    set +e
    (
      set -e
      begin_transaction "projection_rotation" "$CONFIG_DIR" "$OWNER_DIR"
      rotate "$OWNER_DIR/ca.crl" $'-----BEGIN X509 CRL-----\ncm9sbGJhY2stY3Js\n-----END X509 CRL-----'
      if [ "$test_case" = launch_failure_restores_material_and_runtime ]; then : >"$MODEL/fail-next-run"; fi
      update_nginx_config
      if [ "$test_case" = outer_commit_failure_restores_material_and_runtime ]; then : >"$MODEL/fail-commit"; fi
      end_transaction_success
    ) >"$TMP_ROOT/runtime-failure.log" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail_test 'Injected runtime/commit failure unexpectedly succeeded'
    grep -Fq 'Rolled back.' "$TMP_ROOT/runtime-failure.log" || { cat "$TMP_ROOT/runtime-failure.log" >&2; fail_test 'Failure did not finish rollback'; }
    cmp -s "$OWNER_DIR/ca.crl" "$TMP_ROOT/original-crl" || fail_test 'Rollback retained changed source CRL'
    cmp -s "$NGINX_HTTP_CONF_DIR/backends.conf" "$TMP_ROOT/original-config" || fail_test 'Rollback changed prior generated config'
    require_runtime_projection
    cmp -s "$PROJECTION/mtls/owner.example.test/ca.crl" "$TMP_ROOT/original-crl" || fail_test 'Rollback left new CRL mounted in running proxy'
    [ ! -e "$(_transaction_lock_dir)" ] || fail_test 'Rollback leaked mutation lock'
    ;;
  invalid_publication_preserves_runtime)
    rm "$SERVER_DIR/privkey.pem"
    ln -s "$OUTSIDE/sentinel" "$SERVER_DIR/privkey.pem"
    set +e
    (set -e; update_nginx_config) >"$TMP_ROOT/runtime-failure.log" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail_test 'Unsafe certificate input was accepted'
    [ "$(cat "$MODEL/source")" = "$original" ] || fail_test 'Rejected input changed active certificate mount'
    [ ! -s "$MODEL/events" ] || fail_test 'Rejected input changed or reloaded runtime'
    [ -f "$MODEL/running" ] || fail_test 'Rejected input stopped original proxy'
    [ "$(cat "$OUTSIDE/sentinel")" = 'foreign sentinel' ] || fail_test 'Rejected input touched foreign material'
    ;;
  esac
}
