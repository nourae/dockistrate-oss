# shellcheck shell=bash

if [ "$#" -eq 0 ]; then
  failed=0
  for test_case in "${CASES[@]}"; do
    if "$BASH" "$PROJECTION_CASE_RUNNER" --case "$test_case"; then
      printf '[tests] PASS: Nginx certificate projection %s\n' "$test_case"
    else
      printf '[tests] FAIL: Nginx certificate projection %s\n' "$test_case" >&2
      failed=1
    fi
  done
  [ "$failed" -ne 0 ] || printf 'Nginx certificate projection checks passed (%s cases).\n' "${#CASES[@]}"
  exit "$failed"
fi
[ "$#" -eq 2 ] && [ "$1" = --case ] || exit 2
case_found=false
for test_case in "${CASES[@]}"; do [ "$test_case" != "$2" ] || case_found=true; done
[ "$case_found" = true ] || exit 2
CASE_LABEL="$2"

# shellcheck source=lib/nginx_certificate_projection_fixture.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_fixture.sh"

case "$2" in
domain_regular_material | domain_ca_key_link | domain_client_key_link | domain_certificate_key_link | domain_source_swap_link | domain_parent_swap_link)
  # The schema-2 source root contains configuration and private mTLS material
  # as well as serving copies. Server references must never follow links to it.
  source "$ROOT_DIR/lib/domain_config.sh"
  DOMAIN_CONFIG_ACTIVE=true
  DOMAINS_DIR="$STATE_DIR/domains"
  PROJECTION_SOURCE_ROOT="$DOMAINS_DIR"
  SERVER_REF=owner.example.test/public
  SERVER_DIR="$DOMAINS_DIR/owner.example.test/certs/public"
  OWNER_DIR="$DOMAINS_DIR/owner.example.test/mtls"
  mkdir -p "$SERVER_DIR" "$OWNER_DIR" "$DOMAINS_DIR/owner.example.test/config"
  printf 'private configuration\n' >"$DOMAINS_DIR/owner.example.test/config/backend.csv"
  write_material
  write_state
  case "$2" in
  domain_regular_material)
    prepare
    assert_allowlist owner.example.test/certs/public/fullchain.pem owner.example.test/certs/public/privkey.pem \
      owner.example.test/mtls/ca.crt owner.example.test/mtls/ca.crl
    for invalid_policy in '' unsupported; do
      if printf 'complete\0' | _nginx_certificate_projection_helper build "$DOMAINS_DIR" "$TMP_ROOT/invalid-policy" "$invalid_policy" \
        >"$TMP_ROOT/rejection.log" 2>&1; then
        fail_test 'Unexpected server source policy was accepted'
      fi
      [ ! -e "$TMP_ROOT/invalid-policy" ] || fail_test 'Invalid policy modified its destination'
    done
    ;;
  *)
    target="$SERVER_DIR/privkey.pem"
    secret=ca.key
    case "$2" in
    domain_client_key_link) secret=client.key ;;
    domain_certificate_key_link) target="$SERVER_DIR/fullchain.pem" ;;
    domain_source_swap_link | domain_parent_swap_link) _nginx_certificate_projection_manifest >"$TMP_ROOT/manifest" ;;
    esac
    original_secret="$(cat "$OWNER_DIR/$secret")"
    if [ "$2" = domain_parent_swap_link ]; then
      mv "$SERVER_DIR" "$OWNER_DIR/replaced-serving-directory"
      ln -s "$OWNER_DIR/replaced-serving-directory" "$SERVER_DIR"
    else
      rm "$target"
      ln -s "../../mtls/$secret" "$target"
    fi
    if [ "$2" = domain_source_swap_link ] || [ "$2" = domain_parent_swap_link ]; then
      # The fresh worker itself must enforce the policy; an earlier path check
      # in the manifest producer would leave this swap window unprotected.
      if _nginx_certificate_projection_helper build "$DOMAINS_DIR" "$CONFIG_DIR/proxy_certs" regular \
        <"$TMP_ROOT/manifest" >"$TMP_ROOT/rejection.log" 2>&1; then
        fail_test 'Worker followed a server link introduced after the manifest'
      fi
    else
      reject_prepare
    fi
    [ "$(cat "$OWNER_DIR/$secret")" = "$original_secret" ] || fail_test 'Rejected projection changed private material'
    for generation in "$CONFIG_DIR/proxy_certs"/gen-*; do
      [ ! -d "$generation" ] || fail_test 'Rejected linked material published a generation'
    done
    ;;
  esac
  ;;
direct_source_loads_snapshot_dependencies)
  "$BASH" -s -- "$ROOT_DIR" "$TMP_ROOT/direct-source" <<'SH'
set -Eeuo pipefail
root="$1" fixture="$2"
source "$root/lib/nginx/certificate_projection.sh"
[ ! -e "$fixture" ] || exit 1
for helper in _realpath_portable require_valid_var_name _secure_fs_with_file _projection_build _projection_verify_generation _projection_capture _projection_recover _projection_mount_format; do
  declare -F "$helper" >/dev/null || exit 1
done
mkdir -p "$fixture/certificates" "$fixture/config"
selected="$(printf 'complete\0' | _nginx_certificate_projection_helper build "$fixture/certificates" "$fixture/config/proxy_certs")"
_nginx_certificate_projection_helper verify "$fixture/config/proxy_certs" "$selected"
[ -n "$(_projection_mount_format)" ] || exit 1
printf 'mount:%s:false\ncomplete\n' "$(printf '%s' "$selected" | _projection_hex)" |
  _nginx_certificate_projection_helper mounted "$fixture/config/proxy_certs" "$selected"
# Loading by a relative trusted module path must survive a later cwd change,
# including literal newline bytes in that path.
ln -s "$root" "$fixture/modules"$'\n'
cd "$fixture"
source "modules"$'\n/lib/nginx/certificate_projection.sh'
cd /
_nginx_certificate_projection_helper verify "$fixture/config/proxy_certs" "$selected"
SH
  ;;
canonical_root_is_rejected_before_mutation)
  # Model a normalized readonly pin without entering or mutating real `/`.
  # Every later validation/mutation boundary is a rejecting marker, so this
  # regression is safe even when any one root guard is deliberately removed.
  function _secure_fs_pin_directory() {
    [ "$1" = //// ] || return 1
    : >"$TMP_ROOT/root-pin-reached"
    SECURE_FS_PATH=/ SECURE_FS_DEVICE=1 SECURE_FS_INODE=1
    SECURE_FS_MODE=700 SECURE_FS_UID="$EUID"
  }
  function _projection_directory_metadata() { : >"$TMP_ROOT/root-write-reached"; return 1; }
  function _projection_verify_generation() { : >"$TMP_ROOT/root-write-reached"; return 1; }
  function _projection_remove_tree() { : >"$TMP_ROOT/root-write-reached"; return 1; }
  name="gen-$(printf '%064d' 0)-rootguard"
  raw="dockistrate-projection-v2:$EUID:$(id -g)"$'\ncomplete:0\n'
  token="dockistrate-projection-token-v2:$(printf '//%s' "$name" | _projection_hex):1:1:$(printf '%s' "$raw" | _projection_hex)"
  for operation in build verify prune recover; do
    rm -f "$TMP_ROOT/root-pin-reached" "$TMP_ROOT/root-write-reached"
    status=0
    case "$operation" in
    build) _projection_open_private_root //// "$CERTS_DIR" 2:2 || status=$? ;;
    verify | prune) _projection_operate "$operation" //// "//$name" || status=$? ;;
    recover) printf '%s\n' "$token" | _projection_recover //// || status=$? ;;
    esac
    [ "$status" -ne 0 ] || fail_test "Canonical root accepted by $operation"
    [ -f "$TMP_ROOT/root-pin-reached" ] || fail_test "Canonical root guard not exercised by $operation"
    [ ! -f "$TMP_ROOT/root-write-reached" ] || fail_test "Canonical root reached writable boundary in $operation"
  done
  ;;
source_rewrite_during_copy_is_rejected)
  # This fault deliberately targets the in-process worker's copy callback.
  # Normal, runtime and signal-recovery cases use the real fresh boundary.
  function _nginx_certificate_projection_helper() { _nginx_certificate_projection_worker "$@"; }
  _secure_fs_stat_path "$SERVER_DIR/privkey.pem" || fail_test 'Cannot inspect source mutation fixture'
  PROJECTION_TEST_SOURCE_ID="$SECURE_FS_DEVICE:$SECURE_FS_INODE"
  function cat() {
    command cat "$@" || return $?
    if [ "${SECURE_FS_DEVICE:-}:${SECURE_FS_INODE:-}" = "$PROJECTION_TEST_SOURCE_ID" ] &&
      [ ! -f "$TMP_ROOT/source-mutation-reached" ]; then
      : >"$TMP_ROOT/source-mutation-reached"
      # Same length and restored mtime leave ctime as the required metadata
      # evidence; the independently reopened byte comparison is also retained.
      python3 - "$SERVER_DIR/privkey.pem" <<'PY'
import os,sys
path=sys.argv[1]
info=os.stat(path)
with open(path,'wb') as output:
    output.write(b'server private key v2\n')
os.utime(path,ns=(info.st_atime_ns,info.st_mtime_ns))
PY
    fi
  }
  reject_prepare
  [ -f "$TMP_ROOT/source-mutation-reached" ] || fail_test 'Source mutation was not exercised'
  if compgen -G "$CONFIG_DIR/proxy_certs/gen-*" >/dev/null; then fail_test 'Changed source published a snapshot'; fi
  ;;
missing_manifest_has_no_rollback_authority | changed_nested_type_has_no_rollback_authority | capture_stat_failure_is_operational | capture_digest_failure_is_operational)
  prepare
  original="$PROJECTION"
  mounts="mount:$(printf '%s' "$PROJECTION" | _projection_hex):false"$'\ncomplete\n'
  case "$2" in
  missing_manifest_has_no_rollback_authority) rm "$PROJECTION/.dockistrate-projection" ;;
  changed_nested_type_has_no_rollback_authority)
    mv "$PROJECTION/custom" "$TMP_ROOT/old-public-custom"
    printf 'changed nested directory type\n' >"$PROJECTION/custom"
    ;;
  esac
  status=0
  (
    case "$CASE_LABEL" in
    capture_stat_failure_is_operational)
      function _nginx_certificate_projection_helper() { _nginx_certificate_projection_worker "$@"; }
      function stat() { : >"$TMP_ROOT/operational-failure-reached"; return 127; }
      ;;
    capture_digest_failure_is_operational)
      function _nginx_certificate_projection_helper() { _nginx_certificate_projection_worker "$@"; }
      function openssl() { : >"$TMP_ROOT/operational-failure-reached"; return 127; }
      ;;
    esac
    printf '%s' "$mounts" | _nginx_certificate_projection_helper capture "$CONFIG_DIR/proxy_certs" -
  ) >"$TMP_ROOT/cache-capture.log" 2>&1 || status=$?
  case "$2" in
  capture_*_is_operational)
    [ -f "$TMP_ROOT/operational-failure-reached" ] || fail_test 'Operational failure was not reached'
    [ "$status" -eq 1 ] || fail_test 'Operational failure was misclassified as disposable cache damage'
    _nginx_verify_certificate_projection "$PROJECTION" || fail_test 'Failed capture modified active generation'
    ;;
  *)
    [ "$status" -eq 3 ] || fail_test 'Positively damaged cache blocked ordinary recovery'
    prepare
    [ "$PROJECTION" != "$original" ] || fail_test 'Damaged generation was reused'
    assert_default_allowlist
    ;;
  esac
  ;;
snapshot_recovery_rejects_changed_bytes | snapshot_recovery_rejects_changed_token | snapshot_recovery_rejects_outside_symlink)
  set_mapped_key_owner
  prepare
  python3 "$ROOT_DIR/tests/certificate_projection_recovery.py" \
    "$BASH" "$ROOT_DIR/tests/lib/nginx_certificate_projection_driver.sh" "$CONFIG_DIR/proxy_certs" "$PROJECTION" "$OUTSIDE/sentinel" "${2##*_}"
  ;;
inherited_directory_group_empty | inherited_directory_group_populated | inherited_directory_group_nested)
  set_mapped_key_owner
  python3 "$ROOT_DIR/tests/certificate_projection_directory_groups.py" \
    "$BASH" "$ROOT_DIR/tests/lib/nginx_certificate_projection_driver.sh" "$CERTS_DIR" "$CONFIG_DIR/proxy_certs" "${2##*_}"
  ;;
exact_publication_allowlist)
  prepare
  assert_default_allowlist
  directives="$(_backend_mtls_directives admin.owner.example.test)"
  printf '%s\n' "$directives" | grep -Fq '/etc/letsencrypt/mtls/owner.example.test/ca.crt;' || fail_test 'Dedicated-host inheritance lost owner publication'
  ;;
independent_mtls_owners)
  other="$CERTS_DIR/mtls/admin.owner.example.test"
  mkdir -p "$other"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'aW5kZXBlbmRlbnQtY2E=' '-----END CERTIFICATE-----' >"$other/ca.crt"
  printf '%s\n' '-----BEGIN X509 CRL-----' 'aW5kZXBlbmRlbnQtY3Js' '-----END X509 CRL-----' >"$other/ca.crl"
  printf 'independent private CA key\n' >"$other/ca.key"
  printf 'admin.owner.example.test,%s\n' "$other" >>"$BACKEND_MTLS_FILE"
  prepare
  assert_allowlist "$SERVER_REF/fullchain.pem" "$SERVER_REF/privkey.pem" \
    mtls/owner.example.test/ca.crt mtls/owner.example.test/ca.crl \
    mtls/admin.owner.example.test/ca.crt mtls/admin.owner.example.test/ca.crl
  ;;
empty_state_exposes_no_certificates)
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$BACKEND_MTLS_FILE"
  prepare
  assert_allowlist
  ;;
identical_material_reuses_projection | private_client_changes_do_not_publish)
  prepare
  original="$PROJECTION"
  if [ "$2" = private_client_changes_do_not_publish ]; then
    rotate "$OWNER_DIR/client.key" 'rotated private client key'
    rotate "$OWNER_DIR/ca.key" 'rotated private CA key'
    rotate "$OWNER_DIR/index.txt" 'changed private issuer database'
  fi
  prepare
  [ "$PROJECTION" = "$original" ] || fail_test 'Unchanged visible material produced a new projection'
  assert_default_allowlist
  ;;
atomic_crl_rotation | atomic_ca_rotation | atomic_server_certificate_rotation | server_private_key_rotation)
  prepare
  original="$PROJECTION"
  case "$2" in
  atomic_crl_rotation) relative=mtls/owner.example.test/ca.crl ;;
  atomic_ca_rotation) relative=mtls/owner.example.test/ca.crt ;;
  atomic_server_certificate_rotation) relative="$SERVER_REF/fullchain.pem" ;;
  *) relative="$SERVER_REF/privkey.pem" ;;
  esac
  cp "$original/$relative" "$TMP_ROOT/previous-bytes"
  case "$2" in
  atomic_crl_rotation) replacement=$'-----BEGIN X509 CRL-----\nb3duZXItY3JsLXYy\n-----END X509 CRL-----' ;;
  atomic_ca_rotation) replacement=$'-----BEGIN CERTIFICATE-----\nb3duZXItY2EtdjI=\n-----END CERTIFICATE-----' ;;
  *) replacement='replacement public/runtime material v2' ;;
  esac
  rotate "$CERTS_DIR/$relative" "$replacement"
  [ "$2" != server_private_key_rotation ] || chmod 600 "$CERTS_DIR/$relative"
  [ "$2" != atomic_server_certificate_rotation ] || chmod 644 "$CERTS_DIR/$relative"
  prepare
  [ "$PROJECTION" != "$original" ] || fail_test 'Changed certificate bytes reused a stale projection'
  cmp -s "$original/$relative" "$TMP_ROOT/previous-bytes" || fail_test 'Preparation mutated a previously published generation'
  assert_default_allowlist
  ;;
removed_mapping_removes_public_material)
  prepare
  original="$PROJECTION"
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$BACKEND_MTLS_FILE"
  prepare
  [ "$PROJECTION" != "$original" ] || fail_test 'Removed mTLS mapping reused previous publication'
  assert_allowlist "$SERVER_REF/fullchain.pem" "$SERVER_REF/privkey.pem"
  [ -f "$OWNER_DIR/ca.key" ] || fail_test 'Projection removed issuer material'
  ;;
restricted_modes_under_022 | restricted_modes_under_077)
  if [ "$2" = restricted_modes_under_022 ]; then umask 022; else umask 077; fi
  prepare
  assert_default_allowlist
  ;;
letsencrypt_archive_symlinks)
  SERVER_REF=letsencrypt/live/server.example.test
  SERVER_DIR="$CERTS_DIR/$SERVER_REF"
  archive="$CERTS_DIR/letsencrypt/archive/server.example.test"
  mkdir -p "$SERVER_DIR" "$archive"
  printf 'LE public chain\n' >"$archive/fullchain1.pem"
  printf 'LE server private key\n' >"$archive/privkey1.pem"
  chmod 644 "$archive/fullchain1.pem"
  chmod 600 "$archive/privkey1.pem"
  ln -s ../../archive/server.example.test/fullchain1.pem "$SERVER_DIR/fullchain.pem"
  ln -s ../../archive/server.example.test/privkey1.pem "$SERVER_DIR/privkey.pem"
  write_state
  prepare
  assert_default_allowlist
  ;;
external_server_certificate_symlink | external_server_key_symlink | external_mtls_certificate_symlink | external_mtls_crl_symlink)
  case "$2" in
  external_server_certificate_symlink) target="$SERVER_DIR/fullchain.pem" ;;
  external_server_key_symlink) target="$SERVER_DIR/privkey.pem" ;;
  external_mtls_certificate_symlink) target="$OWNER_DIR/ca.crt" ;;
  *) target="$OWNER_DIR/ca.crl" ;;
  esac
  rm "$target"
  ln -s "$OUTSIDE/sentinel" "$target"
  reject_prepare
  ;;
special_file_rejected)
  rm "$SERVER_DIR/privkey.pem"
  mkfifo "$SERVER_DIR/privkey.pem"
  reject_prepare
  ;;
projection_root_symlink_rejected)
  ln -s "$OUTSIDE" "$CONFIG_DIR/proxy_certs"
  reject_prepare
  ;;
published_snapshot_tampering)
  prepare
  original="$PROJECTION"
  printf 'private injected material\n' >"$PROJECTION/injected.key"
  if _nginx_verify_certificate_projection "$original" >"$TMP_ROOT/rejection.log" 2>&1; then fail_test 'Tampered snapshot passed verification'; fi
  prepare
  [ "$PROJECTION" != "$original" ] || fail_test 'Tampered snapshot was reused'
  assert_default_allowlist
  _nginx_prune_certificate_projections "$PROJECTION" || fail_test 'Unable to retire tampered unmounted cache'
  [ ! -e "$original" ] || fail_test 'Retirement retained an obsolete tampered cache'
  ;;
certificate_bytes_are_copied)
  prepare
  python3 - "$PROJECTION/$SERVER_REF/privkey.pem" "$SERVER_DIR/privkey.pem" <<'PY'
import os, sys
a,b=map(os.stat,sys.argv[1:])
assert (a.st_dev,a.st_ino)!=(b.st_dev,b.st_ino), 'Publication shares issuer file inode'
PY
  printf 'source replaced in place\n' >"$SERVER_DIR/privkey.pem"
  [ "$(cat "$PROJECTION/$SERVER_REF/privkey.pem")" = 'server private key v1' ] || fail_test 'Source mutation changed existing generation'
  ;;
combined_mtls_pem_excludes_private_blocks)
  cp "$OWNER_DIR/ca.crt" "$TMP_ROOT/expected-ca"
  cp "$OWNER_DIR/ca.crl" "$TMP_ROOT/expected-crl"
  for public_file in "$OWNER_DIR/ca.crt" "$OWNER_DIR/ca.crl"; do
    printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'c2VjcmV0LW1hdGVyaWFs' '-----END PRIVATE KEY-----' >>"$public_file"
  done
  prepare
  cmp -s "$TMP_ROOT/expected-ca" "$PROJECTION/mtls/owner.example.test/ca.crt" || fail_test 'CA publication included non-certificate material'
  cmp -s "$TMP_ROOT/expected-crl" "$PROJECTION/mtls/owner.example.test/ca.crl" || fail_test 'CRL publication included non-CRL material'
  grep -Fq -- '-----BEGIN PRIVATE KEY-----' "$OWNER_DIR/ca.crt" || fail_test 'Publication rewrote issuer input'
  ;;
restrictive_private_key_metadata | group_readable_private_key_metadata)
  if [ "$2" = restrictive_private_key_metadata ]; then chmod 400 "$SERVER_DIR/privkey.pem"; else set_mapped_key_owner; fi
  prepare
  assert_default_allowlist
  ;;
private_key_mode_change_rotates_generation)
  prepare
  original="$PROJECTION"
  chmod 400 "$SERVER_DIR/privkey.pem"
  prepare
  [ "$PROJECTION" != "$original" ] || fail_test 'Key metadata change reused old access metadata'
  assert_default_allowlist
  ;;
failed_manifest_cannot_publish_partial_material)
  prepare
  original="$PROJECTION"
  before_count="$(find "$CONFIG_DIR/proxy_certs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  rotate "$SERVER_DIR/fullchain.pem" 'new server chain before invalid mTLS state'
  printf 'invalid.example.test,%s\n' "$OUTSIDE" >>"$BACKEND_MTLS_FILE"
  reject_prepare
  after_count="$(find "$CONFIG_DIR/proxy_certs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  [ "$before_count" = "$after_count" ] || fail_test 'Failed manifest producer published a partial generation'
  [ "$(cat "$original/$SERVER_REF/fullchain.pem")" = 'server public certificate v1' ] || fail_test 'Failed producer changed previous publication'
  ;;
hardlinked_private_key_rejected)
  ln "$SERVER_DIR/privkey.pem" "$TMP_ROOT/linked-server-key"
  reject_prepare
  [ "$(cat "$TMP_ROOT/linked-server-key")" = 'server private key v1' ] || fail_test 'Rejected hard link was changed'
  ;;
permission_repair_rebuilds_derived_cache)
  chmod 640 "$SERVER_DIR/privkey.pem"
  prepare
  original="$PROJECTION"
  # shellcheck source=../lib/permissions.sh
  source "$ROOT_DIR/lib/permissions.sh"
  fix_permissions "$CONFIG_DIR" >"$TMP_ROOT/repair.log" 2>&1 || { cat "$TMP_ROOT/repair.log" >&2; fail_test 'Real permission repair failed'; }
  python3 - "$original/$SERVER_REF/privkey.pem" <<'PY'
import os,stat,sys
assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode)==0o600, 'Repair did not exercise stale cache metadata'
PY
  prepare
  [ "$PROJECTION" != "$original" ] || fail_test 'Permission-repaired cache was reused with stale metadata'
  assert_default_allowlist
  _nginx_prune_certificate_projections "$PROJECTION" || fail_test 'Repaired obsolete cache blocked retirement'
  [ ! -e "$original" ] || fail_test 'Repaired obsolete cache retained after retirement'
  ;;
restored_cache_metadata_does_not_block_retirement)
  prepare
  original="$PROJECTION"
  rotate "$OWNER_DIR/ca.crl" $'-----BEGIN X509 CRL-----\ncmVzdG9yZWQtY2FjaGU=\n-----END X509 CRL-----'
  prepare
  selected="$PROJECTION"
  # Restricted archive extraction changes cached modes/ownership. Authoritative
  # source files remain separate; retiring stale derived data must still work.
  python3 - "$original" <<'PY'
import os,pathlib,sys
p=pathlib.Path(sys.argv[1])
for q in [p,*p.rglob('*')]:
    os.chmod(q,0o700 if q.is_dir() else 0o600)
PY
  _nginx_prune_certificate_projections "$selected" || fail_test 'Restored cache metadata prevented retirement'
  [ ! -e "$original" ] || fail_test 'Obsolete restored cache was retained'
  assert_default_allowlist
  _nginx_verify_certificate_projection "$selected" || fail_test 'Retirement damaged selected generation'
  ;;
current_readonly_projection_mount | legacy_broad_mount_requires_recreation | writable_projection_mount_rejected)
  prepare
  mount_source="$PROJECTION"
  mount_rw=false
  case "$2" in
  legacy_broad_mount_requires_recreation) mount_source="$CERTS_DIR" ;;
  writable_projection_mount_rejected) mount_rw=true ;;
  esac
  function docker() {
    [ "$1" = inspect ] && [ "$2" = -f ] || return 91
    case "$3" in
    *'mount:%x:%t'*)
      printf 'mount:'
      printf '%s' "$mount_source" | _projection_hex
      printf ':%s\ncomplete\n' "$mount_rw"
      ;;
    '{{json .Mounts}}')
      python3 - "$mount_source" "$mount_rw" <<'PY'
import json,sys
print(json.dumps([dict(Type='bind',Source=sys.argv[1],Destination='/etc/letsencrypt',RW=sys.argv[2]=='true')]))
PY
      ;;
    *) return 92 ;;
    esac
  }
  status=0
  _nginx_container_has_certificate_projection "$PROJECTION" || status=$?
  if [ "$2" = current_readonly_projection_mount ]; then
    [ "$status" -eq 0 ] || fail_test 'Valid current read-only mount not recognized'
  else
    [ "$status" -ne 0 ] || fail_test 'Unsafe or outdated mount accepted as current'
  fi
  ;;
newline_path_and_mount_identity)
  # Persisted mTLS mappings are line-oriented CSV and cannot encode a newline
  # in their absolute directory field. The relative server reference still
  # exercises literal source/projection paths without changing that contract.
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" >"$BACKEND_MTLS_FILE"
  prepare
  assert_allowlist "$SERVER_REF/fullchain.pem" "$SERVER_REF/privkey.pem"
  case "$PROJECTION" in *$'\n'*) ;; *) fail_test 'Projection assignment lost literal newline path component' ;; esac
  mount_source="$PROJECTION"
  function docker() {
    [ "$1" = inspect ] && [ "$2" = -f ] && [ "$3" = "$(_projection_mount_format)" ] || return 91
    printf 'mount:'
    printf '%s' "$mount_source" | _projection_hex
    printf ':false\ncomplete\n'
  }
  _nginx_container_has_certificate_projection "$PROJECTION" || fail_test 'Literal newline mount identity was lost'
  mount_source="${PROJECTION//$'\n'/}"
  if _nginx_container_has_certificate_projection "$PROJECTION"; then fail_test 'Plain sibling mount matched a newline-containing source'; fi
  ;;
docker_mock_preserves_complete_mount_inventory)
  function fixture_docker() {
    DOCKER_MOCK_RUNTIME_DIR="$TMP_ROOT/mock-runtime" "$ROOT_DIR/tests/mocks/docker" "$@"
  }
  fixture_docker run -d --name projection-fixture --network fixture-net \
    -v "$NGINX_CONFIG_DIR:/etc/nginx/dockistrate:ro" \
    -v "$CONFIG_DIR/proxy_certs/selected:/etc/letsencrypt:ro" \
    -v "$ACME_WEBROOT_DIR:/var/www/certbot:ro" nginx:test >"$TMP_ROOT/mock-id"
  for stage in created network_rewrite stopped restarted; do
    case "$stage" in
    network_rewrite) fixture_docker network connect other-fixture-net projection-fixture ;;
    stopped) fixture_docker stop projection-fixture ;;
    restarted) fixture_docker start projection-fixture ;;
    esac
    fixture_docker inspect -f '{{json .Mounts}}' projection-fixture >"$TMP_ROOT/mock-mounts.json"
    fixture_docker inspect -f '{{.Id}}' projection-fixture >"$TMP_ROOT/current-mock-id"
    cmp -s "$TMP_ROOT/mock-id" "$TMP_ROOT/current-mock-id" || fail_test 'Metadata rewrite changed container identity'
    python3 - "$TMP_ROOT/mock-mounts.json" "$NGINX_CONFIG_DIR" "$CONFIG_DIR/proxy_certs/selected" "$ACME_WEBROOT_DIR" <<'PY'
import json,sys
actual=json.load(open(sys.argv[1]))
expected=[dict(Type='bind',Source=source,Destination=target,RW=False) for source,target in
    zip(sys.argv[2:],['/etc/nginx/dockistrate','/etc/letsencrypt','/var/www/certbot'])]
assert actual==expected, 'Docker mock lost or changed a mount after metadata rewrite: '+repr(actual)
PY
  done
  ;;

*) exit 2 ;;
esac
