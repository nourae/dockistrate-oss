#!/usr/bin/env bash
# Fixture paths are consumed by sourced production helpers.
# shellcheck disable=SC2034,SC1091
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/mtls.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/mtls-state-integrity.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
CERTS_DIR="$TEST_WORK/certs"
MTLS_DIR="$CERTS_DIR/mtls/integrity.example.com"
TEST_CASE="${1:-all}"
mkdir -p "$CERTS_DIR/mtls"

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; cat "$TEST_WORK/output" >&2 2>/dev/null || true; exit 1; }
function snapshot_material() {
  python3 - "$MTLS_DIR" "$1" <<'PY'
import hashlib, json, os, pathlib, stat, sys
root, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
result = {}
if root.exists():
    for path in sorted(root.rglob('*')):
        info = path.lstat()
        value = {'mode': stat.S_IMODE(info.st_mode), 'mtime_ns': info.st_mtime_ns}
        if path.is_symlink(): value['link'] = os.readlink(path)
        elif path.is_file(): value['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        elif path.is_dir(): value['directory'] = True
        else: value['special'] = True
        result[str(path.relative_to(root))] = value
output.write_text(json.dumps(result, sort_keys=True))
PY
}
function reset_material() {
  rm -rf "$MTLS_DIR"
  cp -pR "$TEST_WORK/seed" "$MTLS_DIR"
}
function expect_rejected_unchanged() {
  local label="$1"
  shift
  snapshot_material "$TEST_WORK/before.json"
  if "$@" >"$TEST_WORK/output" 2>&1; then fail_test "$label was accepted"; fi
  snapshot_material "$TEST_WORK/after.json"
  cmp -s "$TEST_WORK/before.json" "$TEST_WORK/after.json" || fail_test "$label changed material before rejecting it"
}
function validate_material() { _mtls_validate_authority_state "$MTLS_DIR" "${1:-core}"; }

# Build real authorities and revocation history. The explicit fresh argument is
# ignored by the old implementation, so missing-file cases reproduce there too.
_generate_backend_ca "$MTLS_DIR" integrity.example.com >"$TEST_WORK/output" 2>&1 || fail_test 'Fresh CA generation failed'
_init_backend_mtls_state "$MTLS_DIR" fresh >"$TEST_WORK/output" 2>&1 || fail_test 'Fresh database initialization failed'
_generate_backend_crl "$MTLS_DIR" >"$TEST_WORK/output" 2>&1 || fail_test 'Fresh CRL generation failed'
cp -pR "$MTLS_DIR" "$TEST_WORK/unused"
_issue_backend_client_cert "$MTLS_DIR" valid-client >"$TEST_WORK/output" 2>&1 || fail_test 'Valid client fixture failed'
_issue_backend_client_cert "$MTLS_DIR" revoked-client >"$TEST_WORK/output" 2>&1 || fail_test 'Revoked client fixture failed'
(
  cd "$MTLS_DIR"
  openssl ca -batch -config openssl.cnf -revoke revoked-client.crt >/dev/null 2>&1
) || fail_test 'Fixture revocation failed'
_generate_backend_crl "$MTLS_DIR" >"$TEST_WORK/output" 2>&1 || fail_test 'Fixture revocation-list generation failed'
cp -pR "$MTLS_DIR" "$TEST_WORK/seed"

for file in ca.crt ca.key index.txt serial crlnumber; do
  case "$TEST_CASE" in all | "missing-$file") ;; *) continue ;; esac
  reset_material
  rm "$MTLS_DIR/$file"
  expect_rejected_unchanged "existing authority missing $file" _init_backend_mtls_state "$MTLS_DIR"
  printf '[PASS] Missing %s is rejected without resetting material\n' "$file"
done
if [ "$TEST_CASE" != all ]; then
  case "$TEST_CASE" in missing-ca.crt | missing-ca.key | missing-index.txt | missing-serial | missing-crlnumber) exit 0 ;; *) fail_test "Unknown case: $TEST_CASE" ;; esac
fi

for variant in bad-index short-index-serial odd-index-serial duplicate-serial bad-serial odd-serial odd-crlnumber bad-crlnumber nul-serial nul-crlnumber nul-filename nul-subject filename-backslash unterminated-index empty-revoked-index stale-crl malformed-crl; do
  reset_material
  case "$variant" in
  bad-index) printf 'V\tinvalid-date\t\t1000\tunknown\t/CN=client\n' >"$MTLS_DIR/index.txt" ;;
  short-index-serial | odd-index-serial)
    row_serial=A
    [ "$variant" != odd-index-serial ] || row_serial=ABC
    awk -F '\t' -v serial="$row_serial" 'BEGIN { OFS="\t" } NR == 1 { $4=serial } { print }' "$MTLS_DIR/index.txt" >"$TEST_WORK/row"
    cat "$TEST_WORK/row" >"$MTLS_DIR/index.txt"
    ;;
  duplicate-serial) sed -n '1p' "$MTLS_DIR/index.txt" >"$TEST_WORK/row"; cat "$TEST_WORK/row" >>"$MTLS_DIR/index.txt" ;;
  odd-serial) printf 'A\n' >"$MTLS_DIR/serial" ;;
  odd-crlnumber) printf '101\n' >"$MTLS_DIR/crlnumber" ;;
  bad-serial) printf 'not-hex\n' >"$MTLS_DIR/serial" ;;
  bad-crlnumber) printf '1001\n1002\n' >"$MTLS_DIR/crlnumber" ;;
  nul-serial) printf '1001\0\n' >"$MTLS_DIR/serial" ;;
  nul-crlnumber) printf '1001\0\n' >"$MTLS_DIR/crlnumber" ;;
  nul-filename | nul-subject | filename-backslash | unterminated-index)
    python3 - "$MTLS_DIR/index.txt" "$variant" <<'PY_INDEX'
import pathlib, sys
path, variant = pathlib.Path(sys.argv[1]), sys.argv[2]
data = path.read_bytes()
if variant == 'unterminated-index':
    assert data.endswith(b'\n')
    data = data[:-1]
else:
    rows = data.splitlines(keepends=True)
    fields = rows[0].split(b'\t')
    if variant == 'nul-filename': fields[4] += bytes([0]) + b'ignored'
    elif variant == 'nul-subject': fields[5] = fields[5][:-1] + bytes([0]) + b'ignored\n'
    else: fields[4] += bytes([92])
    rows[0] = b'\t'.join(fields)
    data = b''.join(rows)
path.write_bytes(data)
PY_INDEX
    ;;
  empty-revoked-index) : >"$MTLS_DIR/index.txt" ;;
  stale-crl) cp "$TEST_WORK/unused/ca.crl" "$MTLS_DIR/ca.crl" ;;
  malformed-crl) printf 'not a CRL\n' >"$MTLS_DIR/ca.crl" ;;
  esac
  expect_rejected_unchanged "$variant" validate_material
done

reset_material
: >"$MTLS_DIR/index.txt"
expect_rejected_unchanged 'regeneration with forgotten revocations' _generate_backend_crl "$MTLS_DIR"

# A correctly signed older CRL must not revive revoked clients. Only the
# explicit generator may repair lag after a normal database revocation update.
reset_material
cp "$TEST_WORK/unused/ca.crl" "$MTLS_DIR/ca.crl"
_generate_backend_crl "$MTLS_DIR" >"$TEST_WORK/output" 2>&1 || fail_test 'CRL regeneration did not repair recorded revocation lag'
validate_material complete >"$TEST_WORK/output" 2>&1 || fail_test 'Regenerated CRL still disagrees with database'
if openssl verify -CAfile "$MTLS_DIR/ca.crt" -CRLfile "$MTLS_DIR/ca.crl" -crl_check "$MTLS_DIR/revoked-client.crt" >"$TEST_WORK/output" 2>&1; then fail_test 'Regeneration reinstated revoked client'; fi

# Refuse links and special files before OpenSSL can follow or block on them.
for file in ca.crt ca.key index.txt serial crlnumber ca.crl; do
  reset_material
  cp "$MTLS_DIR/$file" "$TEST_WORK/outside"
  rm "$MTLS_DIR/$file"
  ln -s "$TEST_WORK/outside" "$MTLS_DIR/$file"
  expect_rejected_unchanged "symlinked $file" validate_material
done
reset_material
rm "$MTLS_DIR/index.txt"
mkfifo "$MTLS_DIR/index.txt"
expect_rejected_unchanged 'FIFO database' validate_material

other="$CERTS_DIR/mtls/other.example.com"
_generate_backend_ca "$other" integrity.example.com >"$TEST_WORK/output" 2>&1 || fail_test 'Second CA generation failed'
_init_backend_mtls_state "$other" fresh >"$TEST_WORK/output" 2>&1 || fail_test 'Second database initialization failed'
_generate_backend_crl "$other" >"$TEST_WORK/output" 2>&1 || fail_test 'Second CRL generation failed'
reset_material
cp "$other/ca.key" "$MTLS_DIR/ca.key"
expect_rejected_unchanged 'mismatched CA key' validate_material
reset_material
cp "$other/ca.crl" "$MTLS_DIR/ca.crl"
expect_rejected_unchanged 'CRL signed by another CA' validate_material

# Empty history is legitimate for an unused authority. Validation itself is
# read-only, including file modification times, for populated and empty state.
for fixture in unused seed; do
  rm -rf "$MTLS_DIR"
  cp -pR "$TEST_WORK/$fixture" "$MTLS_DIR"
  snapshot_material "$TEST_WORK/before.json"
  validate_material complete >"$TEST_WORK/output" 2>&1 || fail_test "Valid $fixture authority rejected"
  snapshot_material "$TEST_WORK/after.json"
  cmp -s "$TEST_WORK/before.json" "$TEST_WORK/after.json" || fail_test 'Read-only validation modified material'
done

# OpenSSL accepts non-NUL control bytes in subjects. The parser checks must
# reject damaged records without adding a broader historical-subject policy.
reset_material
python3 - "$MTLS_DIR/index.txt" <<'PY_SUBJECT'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_bytes(path.read_bytes().replace(b'/CN=valid-client', b'/CN=valid' + bytes([31]) + b'client', 1))
PY_SUBJECT
validate_material complete >"$TEST_WORK/output" 2>&1 || fail_test 'Validation rejected an OpenSSL-compatible non-NUL subject byte'

# Structural integrity does not introduce a new expiry policy for retained
# authorities. Re-signing with the same key preserves identity and CRL issuer.
reset_material
cat >"$TEST_WORK/ca-extensions" <<'EXTENSIONS'
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EXTENSIONS
(
  cd "$MTLS_DIR"
  openssl req -new -key ca.key -subj '/CN=integrity.example.com CA' -out "$TEST_WORK/expired-ca.csr" &&
    openssl ca -batch -selfsign -notext -config openssl.cnf -in "$TEST_WORK/expired-ca.csr" -out "$TEST_WORK/expired-ca.crt" \
      -startdate 200101000000Z -enddate 200102000000Z -extfile "$TEST_WORK/ca-extensions" -extensions ca
) >"$TEST_WORK/output" 2>&1 || fail_test 'Expired CA fixture failed'
cp "$TEST_WORK/expired-ca.crt" "$MTLS_DIR/ca.crt"
if openssl x509 -in "$MTLS_DIR/ca.crt" -checkend 0 -noout >"$TEST_WORK/output" 2>&1; then fail_test 'Expired CA fixture is not expired'; fi
validate_material complete >"$TEST_WORK/output" 2>&1 || fail_test 'Structural validation introduced a new CA expiry policy'

reset_material
(
  cd "$MTLS_DIR"
  openssl ca -batch -gencrl -config openssl.cnf -crlsec 1 -out ca.crl
) >"$TEST_WORK/output" 2>&1 || fail_test 'Expiring CRL fixture failed'
sleep 2
if openssl verify -CAfile "$MTLS_DIR/ca.crt" -CRLfile "$MTLS_DIR/ca.crl" -crl_check "$MTLS_DIR/valid-client.crt" >"$TEST_WORK/output" 2>&1; then fail_test 'Expired CRL fixture is still current'; fi
grep -Fq 'CRL has expired' "$TEST_WORK/output" || fail_test 'CRL fixture failed verification for a different reason'
validate_material complete >"$TEST_WORK/output" 2>&1 || fail_test 'Structural validation introduced a new CRL expiry policy'

# Derived-file recovery must retain the authority and the revocation database.
reset_material
rm "$MTLS_DIR/openssl.cnf" "$MTLS_DIR/ca.crl"
rm -rf "$MTLS_DIR/newcerts"
_init_backend_mtls_state "$MTLS_DIR" >"$TEST_WORK/output" 2>&1 || fail_test 'Derived configuration recovery failed'
_generate_backend_crl "$MTLS_DIR" >"$TEST_WORK/output" 2>&1 || fail_test 'Missing CRL recovery failed'
for file in ca.crt ca.key index.txt serial valid-client.crt revoked-client.crt; do
  cmp -s "$TEST_WORK/seed/$file" "$MTLS_DIR/$file" || fail_test "Derived-file recovery changed $file"
done
validate_material complete >"$TEST_WORK/output" 2>&1 || fail_test 'Recovered authority is invalid'
openssl verify -CAfile "$MTLS_DIR/ca.crt" -CRLfile "$MTLS_DIR/ca.crl" -crl_check "$MTLS_DIR/valid-client.crt" >"$TEST_WORK/output" 2>&1 || fail_test 'Recovery rejected a valid client'
if openssl verify -CAfile "$MTLS_DIR/ca.crt" -CRLfile "$MTLS_DIR/ca.crl" -crl_check "$MTLS_DIR/revoked-client.crt" >"$TEST_WORK/output" 2>&1; then fail_test 'Recovery reinstated a revoked client'; fi

# Listing uses production formatting, but the lookup is isolated from shared
# installation state. It must not create bookkeeping, configuration or outputs.
function get_backend_mtls_dir() { printf '%s\n' "$MTLS_DIR"; }
reset_material
rm "$MTLS_DIR/openssl.cnf"
rm -rf "$MTLS_DIR/newcerts"
snapshot_material "$TEST_WORK/before.json"
list_backend_client_certs integrity.example.com >"$TEST_WORK/output" 2>&1 || fail_test 'Listing valid retained state failed'
grep -Fq 'valid-client (valid)' "$TEST_WORK/output" || fail_test 'Listing lost valid client status'
grep -Fq 'revoked-client (revoked)' "$TEST_WORK/output" || fail_test 'Listing lost revocation status'
snapshot_material "$TEST_WORK/after.json"
cmp -s "$TEST_WORK/before.json" "$TEST_WORK/after.json" || fail_test 'Listing mutated authority state'
rm "$MTLS_DIR/index.txt"
expect_rejected_unchanged 'listing missing history' list_backend_client_certs integrity.example.com
function _resolve_backend_mtls_dir() { printf -v "$1" '%s' "$MTLS_DIR"; }
TEST_EXPORT_PASSWORD='fixture-password'
expect_rejected_unchanged 'exporting with missing history' export_backend_client_p12 integrity.example.com valid-client --password-env TEST_EXPORT_PASSWORD

reset_material
expect_rejected_unchanged 'implicit replacement of retained authority' _generate_backend_ca "$MTLS_DIR" integrity.example.com
# Material introduced after the first emptiness check must not be overwritten.
late="$CERTS_DIR/mtls/late.example.com"
eval "$(declare -f _mtls_prepare_dir_for_mutation | sed '1s/_mtls_prepare_dir_for_mutation/_test_prepare_dir_for_mutation/')"
function _mtls_prepare_dir_for_mutation() {
  _test_prepare_dir_for_mutation "$@" || return 1
  printf 'retained late key\n' >"$late/ca.key"
}
if _generate_backend_ca "$late" late.example.com >"$TEST_WORK/output" 2>&1; then fail_test 'Generation overwrote material introduced during preparation'; fi
[ "$(cat "$late/ca.key")" = 'retained late key' ] || fail_test 'Late authority key was replaced'
[ ! -e "$late/ca.crt" ] || fail_test 'Generation created a certificate over late authority material'
printf '[PASS] Existing mTLS identity/history are validated without reset; derived recovery retains revocations and listing is read-only\n'
