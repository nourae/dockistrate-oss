# shellcheck shell=bash

# shellcheck source=../../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../../lib/backups.sh
source "$ROOT_DIR/lib/backups.sh"
# shellcheck source=../../lib/mtls.sh
source "$ROOT_DIR/lib/mtls.sh"
# shellcheck source=../../lib/nginx.sh
source "$ROOT_DIR/lib/nginx.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_certificate_projection.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'status=$?; if [ "$status" -eq 0 ]; then rm -rf -- "$TMP_ROOT"; else printf "[tests] Failed certificate projection fixture retained: %s\n" "$TMP_ROOT" >&2; fi; exit "$status"' EXIT
# The literal base path is used in every case, including Docker source checks.
BASE_DIR="$TMP_ROOT/base with spaces[glob]"
if [ "$CASE_LABEL" = newline_path_and_mount_identity ]; then BASE_DIR="${BASE_DIR}"$'\n'; fi
STATE_DIR="$BASE_DIR/state"
CONFIG_DIR="$STATE_DIR/config"
TMP_DIR="$STATE_DIR/tmp"
LOG_DIR="$STATE_DIR/logs"
ERROR_LOG_DIR="$LOG_DIR/errors"
BACKUP_DIR="$STATE_DIR/backups"
LAST_POST_BACKUP_FILE="$BACKUP_DIR/last_post_backup.txt"
CONFIG_CHECKSUM_FILE="$BACKUP_DIR/last_config.sha256"
GLOBAL_SETTINGS_FILE="$CONFIG_DIR/global_settings.csv"
CERTS_DIR="$STATE_DIR/certs"
NGINX_CONFIG_DIR="$CONFIG_DIR/nginx_conf"
NGINX_HTTP_CONF_DIR="$NGINX_CONFIG_DIR/conf.d"
NGINX_STREAM_CONF_DIR="$NGINX_CONFIG_DIR/stream_conf"
BACKEND_PORTS_FILE="$CONFIG_DIR/backend_ports.csv"
BACKEND_ALIASES_FILE="$CONFIG_DIR/backend_aliases.csv"
BACKEND_MTLS_FILE="$CONFIG_DIR/backend_mtls.csv"
ACME_WEBROOT_DIR="$STATE_DIR/acme-webroot"
CAPTURE_DIR="$STATE_DIR/pcaps"
CAPTURE_TLS_STATE_FILE="$CONFIG_DIR/capture_tls_decrypt.state"
SERVER_REF=custom/live/server.example.test
SERVER_DIR="$CERTS_DIR/$SERVER_REF"
OWNER_DIR="$CERTS_DIR/mtls/owner.example.test"
OUTSIDE="$TMP_ROOT/outside"
PROJECTION=''
mkdir -p "$SERVER_DIR" "$OWNER_DIR" "$NGINX_HTTP_CONF_DIR" "$NGINX_STREAM_CONF_DIR" "$TMP_DIR" "$OUTSIDE"
chmod 755 "$OUTSIDE"
printf 'foreign sentinel\n' >"$OUTSIDE/sentinel"
chmod 640 "$OUTSIDE/sentinel"

function fail_test() { printf '[Error] %s: %s\n' "$CASE_LABEL" "$*" >&2; exit 1; }
function docker() { printf '[Error] Pure certificate projection fixture called Docker: %s\n' "$*" >&2; return 91; }
function write_state() {
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" \
    'backend,owner.example.test,127.0.0.1:8000,fixture-net,,,,,,,,,,,,,,,,,' \
    "port,owner.example.test,,,,,443,8000,https,$SERVER_REF,no,off,,off,auto,,,,,," >"$BACKEND_PORTS_FILE"
  printf '%s\n' "$STATE_BACKEND_ALIASES_HEADER" \
    'dedicated,admin.owner.example.test,owner.example.test' >"$BACKEND_ALIASES_FILE"
  printf '%s\n' "$STATE_BACKEND_MTLS_HEADER" "owner.example.test,$OWNER_DIR" >"$BACKEND_MTLS_FILE"
}
function write_material() {
  printf 'server public certificate v1\n' >"$SERVER_DIR/fullchain.pem"
  printf 'server private key v1\n' >"$SERVER_DIR/privkey.pem"
  printf '%s\n' '-----BEGIN CERTIFICATE-----' 'b3duZXItY2EtdjE=' '-----END CERTIFICATE-----' >"$OWNER_DIR/ca.crt"
  printf '%s\n' '-----BEGIN X509 CRL-----' 'b3duZXItY3JsLXYx' '-----END X509 CRL-----' >"$OWNER_DIR/ca.crl"
  printf 'private owner CA key\n' >"$OWNER_DIR/ca.key"
  printf 'private client key\n' >"$OWNER_DIR/client.key"
  printf 'private client bundle\n' >"$OWNER_DIR/client.p12"
  printf 'unneeded client certificate\n' >"$OWNER_DIR/client.crt"
  printf 'unneeded issuer database\n' >"$OWNER_DIR/index.txt"
  printf 'unneeded issuer configuration\n' >"$OWNER_DIR/openssl.cnf"
  mkdir -p "$OWNER_DIR/newcerts" "$CERTS_DIR/custom/live/unmapped.example.test" "$CERTS_DIR/letsencrypt/accounts"
  printf 'unneeded issued certificate\n' >"$OWNER_DIR/newcerts/01.pem"
  printf 'unmapped server secret\n' >"$CERTS_DIR/custom/live/unmapped.example.test/privkey.pem"
  printf 'ACME account private key\n' >"$CERTS_DIR/letsencrypt/accounts/private_key.json"
  # Keep the intended public fixture mode independent of runner umask002.
  chmod 644 "$SERVER_DIR/fullchain.pem"
  chmod 600 "$SERVER_DIR/privkey.pem" "$OWNER_DIR/ca.key" "$OWNER_DIR/client.key" "$OWNER_DIR/client.p12"
}
function prepare() {
  PROJECTION=''
  _nginx_prepare_certificate_projection PROJECTION || fail_test 'Projection preparation failed'
  [ -n "$PROJECTION" ] && [ -d "$PROJECTION" ] && [ ! -L "$PROJECTION" ] || fail_test 'Projection is not a real directory'
  case "$PROJECTION" in "$NGINX_CONFIG_DIR" | "$NGINX_CONFIG_DIR"/* | "$CERTS_DIR" | "$CERTS_DIR"/*) fail_test 'Projection lies inside a broad/default mounted source' ;; esac
}
function assert_allowlist() {
  python3 - "$PROJECTION" "${PROJECTION_SOURCE_ROOT:-$CERTS_DIR}" "$@" <<'PY'
import json, os, pathlib, stat, sys
root, source = map(pathlib.Path, sys.argv[1:3])
expected = set(sys.argv[3:])
actual = set()
for path in root.rglob('*'):
    info = path.lstat()
    assert not stat.S_ISLNK(info.st_mode), 'Published symlink: ' + str(path)
    if stat.S_ISDIR(info.st_mode):
        assert not info.st_mode & 0o022, 'Writable directory: ' + str(path)
        continue
    assert stat.S_ISREG(info.st_mode), 'Published special file: ' + str(path)
    relative = path.relative_to(root).as_posix()
    if relative == '.dockistrate-projection':
        lines = path.read_text(encoding='ascii').splitlines()
        assert lines[0].startswith('dockistrate-projection-v2:'), 'Unknown manifest version'
        assert lines[-1] == 'complete:%d' % (len(lines)-2), 'Incomplete manifest'
        for row in lines[1:-1]:
            encoded, role, mode, uid, gid, digest = row.split(':')
            assert bytes.fromhex(encoded).decode() in expected, 'Unexpected manifest path'
            assert int(mode,8) >= 0 and int(uid) >= 0 and int(gid) >= 0 and len(digest) == 64
        for secret in (b'private owner CA key', b'private client key', b'private client bundle', b'ACME account private key'):
            assert secret not in path.read_bytes(), 'Manifest exposed private input bytes'
        continue
    actual.add(relative)
    assert relative in expected, 'Unexpected proxy-visible file: ' + relative
    assert path.read_bytes() == (source / relative).read_bytes(), 'Incorrect published bytes: ' + relative
    assert not info.st_mode & 0o022, 'Writable file: ' + relative
    if relative.endswith('/privkey.pem'):
        original = (source / relative).stat()
        assert stat.S_IMODE(info.st_mode) == stat.S_IMODE(original.st_mode), 'Server private key mode changed'
        assert (info.st_uid, info.st_gid) == (original.st_uid, original.st_gid), 'Server private key ownership changed'
assert actual == expected, 'Missing published files: ' + repr(expected - actual)
PY
}
function assert_default_allowlist() {
  assert_allowlist "$SERVER_REF/fullchain.pem" "$SERVER_REF/privkey.pem" \
    mtls/owner.example.test/ca.crt mtls/owner.example.test/ca.crl
}
function reject_prepare() {
  local status=0
  _nginx_prepare_certificate_projection PROJECTION >"$TMP_ROOT/rejection.log" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail_test 'Unsafe input was accepted'
  [ "$(cat "$OUTSIDE/sentinel")" = 'foreign sentinel' ] || fail_test 'Foreign file changed'
  python3 - "$OUTSIDE" <<'PY'
import pathlib, stat, sys
p=pathlib.Path(sys.argv[1])
assert stat.S_IMODE(p.stat().st_mode)==0o755
assert stat.S_IMODE((p/'sentinel').stat().st_mode)==0o640
assert sorted(q.name for q in p.iterdir())==['sentinel']
PY
}
function rotate() { printf '%s\n' "$2" >"$1.new"; mv -f "$1.new" "$1"; }
function set_mapped_key_owner() {
  # Privileged local runs exercise a different numeric container identity;
  # unprivileged CI still verifies exact preservation of its usable identity.
  python3 - "$SERVER_DIR/privkey.pem" <<'PY'
import os,sys
if os.geteuid()==0:
    os.chown(sys.argv[1],12345,12345)
os.chmod(sys.argv[1],0o640)
PY
}
write_state
write_material
