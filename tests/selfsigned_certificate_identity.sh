#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/selfsigned-identity.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
# Exercise the real certificate generation and permissions without Docker or
# unrelated backup/render work. Full command publication has separate coverage.
source "$ROOT_DIR/lib/utils/validators.sh"
source "$ROOT_DIR/lib/certs/add_cert.sh"
CERTS_DIR="$TEST_WORK/certs"
ACME_WEBROOT_DIR="$TEST_WORK/acme"
INTERACTIVE=false
CERT_AUTOCONFIG_DISABLED=1
SKIP_UPDATE_NGINX_CONFIG=true
function _config_begin_transaction_if_needed() { printf -v "$1" '%s' false; }
function _config_end_transaction_if_started() { :; }
function create_backup() { :; }
function _rollback_handler() { exit 1; }

add_cert Example.Test 443 selfsigned
add_cert 127.0.0.1 443 selfsigned
python3 - "$CERTS_DIR" <<'PY'
from pathlib import Path
import ssl
import stat
import sys

root = Path(sys.argv[1]) / "selfsigned/live"
for domain, identity_type in [("example.test", "DNS"), ("127.0.0.1", "IP Address")]:
    certificate = root / (domain + "_443") / "fullchain.pem"
    decoded = ssl._ssl._test_decode_cert(str(certificate))
    assert decoded["subjectAltName"] == ((identity_type, domain),), decoded
    key = certificate.with_name("privkey.pem")
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert stat.S_IMODE(certificate.stat().st_mode) == 0o640
print("[PASS] self-signed DNS and IP certificates carry the matching SAN and restricted key modes")
PY
