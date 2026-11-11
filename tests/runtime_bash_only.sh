#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
GUARD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-no-python.XXXXXXXX")"
GUARD_DIR="$(cd "$GUARD_DIR" && pwd -P)"
trap 'status=$?; rm -rf -- "$GUARD_DIR"; exit "$status"' EXIT
mkdir "$GUARD_DIR/bin"
export PYTHON_CALL_LOG="$GUARD_DIR/python-called"
cat >"$GUARD_DIR/bin/python" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$0" >>"$PYTHON_CALL_LOG"
printf '[Error] Production code attempted to run Python.\n' >&2
exit 97
STUB
chmod +x "$GUARD_DIR/bin/python"
for python_name in python2 python2.7 python3 python3.8 python3.9 python3.10 python3.11 python3.12 python3.13 python3.14 python3.15; do
  ln -s python "$GUARD_DIR/bin/$python_name"
done
PATH="$GUARD_DIR/bin:$PATH"
export PATH

# The fixture creates literal-path certificate/state samples using Bash. Its
# Python assertion helpers are deliberately not used: every operation and
# assertion below must succeed while the Python executables are poisoned.
CASE_LABEL=runtime_bash_only
# shellcheck source=lib/nginx_certificate_projection_fixture.sh
source "$ROOT_DIR/tests/lib/nginx_certificate_projection_fixture.sh"
trap 'status=$?; rm -rf -- "$GUARD_DIR"; if [ "$status" -eq 0 ]; then rm -rf -- "$TMP_ROOT"; else printf "[tests] Failed Bash-only fixture retained: %s\n" "$TMP_ROOT" >&2; fi; exit "$status"' EXIT
# shellcheck source=../lib/permissions/metadata_io.sh
source "$ROOT_DIR/lib/permissions/metadata_io.sh"
# shellcheck source=../lib/capture/output_io.sh
source "$ROOT_DIR/lib/capture/output_io.sh"

_permissions_metadata_helper_check || fail_test 'Permission helper unavailable'
_secure_fs_stat_path "$SERVER_DIR" || fail_test 'Permission root stat'
permission_device="$SECURE_FS_DEVICE" permission_inode="$SECURE_FS_INODE"
_secure_fs_stat_path "$SERVER_DIR/privkey.pem" || fail_test 'Permission file stat'
_permissions_metadata_helper_run "$SERVER_DIR" "$permission_device" "$permission_inode" \
  "$SERVER_DIR/privkey.pem" file "$SECURE_FS_DEVICE" "$SECURE_FS_INODE" \
  "$SECURE_FS_UID" "$SECURE_FS_GID" "$SECURE_FS_MODE" chmod 600 '' || fail_test 'Permission repair'
printf '[PASS] Permission repair without Python\n'

_capture_output_run preflight "$CAPTURE_DIR" "$CAPTURE_DIR/session" || fail_test 'Capture preflight'
capture_result="$(_capture_output_run prepare "$CAPTURE_DIR" "$CAPTURE_DIR/session")" || fail_test 'Capture prepare'
capture_identity="${capture_result##*$'\n'}"
_capture_output_run verify "$CAPTURE_DIR" "$CAPTURE_DIR/session" "$capture_identity" || fail_test 'Capture verify'
printf '[PASS] Capture preparation without Python\n'

prepare
cmp "$PROJECTION/$SERVER_REF/privkey.pem" "$SERVER_DIR/privkey.pem" || fail_test 'Server key bytes changed'
[ ! -e "$PROJECTION/mtls/owner.example.test/ca.key" ] || fail_test 'CA key exposed'
[ ! -e "$PROJECTION/mtls/owner.example.test/client.key" ] || fail_test 'Client key exposed'
[ ! -e "$PROJECTION/mtls/owner.example.test/client.p12" ] || fail_test 'Client export exposed'
_nginx_verify_certificate_projection "$PROJECTION" || fail_test 'Projection verification'
printf '[PASS] Certificate projection without Python\n'

function docker() {
  [ "${1:-}" = inspect ] || return 91
  printf 'mount:%s:false\ncomplete\n' "$(printf '%s' "$PROJECTION" | _projection_hex)"
}
_nginx_container_has_certificate_projection "$PROJECTION" || fail_test 'Mount verification'
projection_token="$(docker inspect | _nginx_certificate_projection_helper capture "${CONFIG_DIR}/proxy_certs" -)" || fail_test 'Projection rollback capture'
recovered=''
_nginx_recover_certificate_projection recovered "$projection_token" || fail_test 'Projection recovery'
[ "$recovered" = "$PROJECTION" ] || fail_test 'Unchanged generation was not reused'
_nginx_prune_certificate_projections "$recovered" || fail_test 'Projection retirement'
printf '[PASS] Mount verification and rollback without Python\n'

[ ! -e "$PYTHON_CALL_LOG" ] || fail_test 'A Python invocation was attempted'
printf '[PASS] Runtime Python invocation guard\n'
