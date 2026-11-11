#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/backups.sh"
source "$ROOT_DIR/lib/domain_config.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_domain_certs.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
STATE_DIR="$TEST_ROOT/state"
CERTS_DIR="$STATE_DIR/certs"
DOMAINS_DIR="$STATE_DIR/domains"
DOMAIN_CONFIG_ACTIVE=true
mkdir -p "$DOMAINS_DIR/example.com/certs/custom-443" "$DOMAINS_DIR/example.com/mtls"

function fail() { echo "[Error] $*" >&2; exit 1; }
normalized="" owner="" cert_id="" container_path=""
normalize_cert_dir normalized example.com/custom-443
[ "$normalized" = "$DOMAINS_DIR/example.com/certs/custom-443" ] || fail 'Canonical certificate reference did not resolve'
normalize_cert_dir normalized custom/live/example.com_443
[ "$normalized" = "$DOMAINS_DIR/example.com/certs/custom-443" ] || fail 'Legacy certificate reference did not resolve'
cert_ref_to_container_dir container_path example.com/custom-443
[ "$container_path" = /etc/letsencrypt/example.com/certs/custom-443 ] || fail 'Container certificate path is incorrect'
relativize_cert_dir normalized "$DOMAINS_DIR/example.com/certs/custom-443"
[ "$normalized" = example.com/custom-443 ] || fail 'Canonical certificate reference changed'
for resolver in normalize_cert_dir cert_ref_to_container_dir; do
  for unsafe_ref in /tmp/outside certs/../../etc example.com/../../outside; do
    normalized=unchanged
    if "$resolver" normalized "$unsafe_ref" >"$TEST_ROOT/path-error" 2>&1; then
      fail "$resolver accepted an external or traversing certificate reference"
    fi
    [ "$normalized" = unchanged ] || fail "$resolver changed its destination after rejecting a reference"
    grep -Fq "Certificate directory '$unsafe_ref' must reside within '$DOMAINS_DIR/" "$TEST_ROOT/path-error" ||
      fail "$resolver omitted actionable certificate containment guidance"
    grep -Fq 'managed owner/id reference' "$TEST_ROOT/path-error" || fail "$resolver omitted the supported reference format"
  done
done
if _domain_mtls_resolve normalized "$DOMAINS_DIR/example.com/mtls" other.example.com >/dev/null 2>&1; then fail 'mTLS cross-owner path accepted'; fi
_domain_mtls_resolve normalized "$DOMAINS_DIR/example.com/mtls" example.com
# Resolution returns the physical owned directory; macOS TMPDIR commonly uses
# /var while the physical path begins /private/var.
owned_mtls_physical="$(cd "$DOMAINS_DIR/example.com/mtls" && pwd -P)"
[ "$normalized" = "$owned_mtls_physical" ] || fail 'mTLS owner path did not resolve'
mkdir -p "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$DOMAINS_DIR/example.com/certs/linked"
if normalize_cert_dir normalized example.com/linked >/dev/null 2>&1; then fail 'Certificate symlink escape accepted'; fi

# Saved migration references are an exact map, including after a certificate
# takes a descriptive ID and the legacy serving directory no longer exists.
alias_material="$DOMAINS_DIR/alias.example.com/certs/public-tls"
legacy_reference="$CERTS_DIR/custom/live/alias.example.com_443"
mkdir -p "$alias_material" "$CERTS_DIR/custom/live"
_domain_cert_write_metadata "$alias_material" custom 443 "$legacy_reference"
for legacy_spelling in custom/live/alias.example.com_443 ./certs/custom/./live/alias.example.com_443/ "$legacy_reference/"; do
  normalize_cert_dir normalized "$legacy_spelling"
  [ "$normalized" = "$alias_material" ] || fail 'Saved legacy reference did not select its descriptive certificate ID'
  relativize_cert_dir normalized "$legacy_spelling"
  [ "$normalized" = alias.example.com/public-tls ] || fail 'Legacy reference canonicalization ignored its saved mapping'
  cert_ref_to_container_dir container_path "$legacy_spelling"
  [ "$container_path" = /etc/letsencrypt/alias.example.com/certs/public-tls ] || fail 'Legacy reference generated the wrong container path'
done
[ ! -e "$legacy_reference" ] || fail 'Reference lookup recreated legacy material'

renewal_material="$DOMAINS_DIR/alias.example.com/certs/renewable"
mkdir -p "$renewal_material"
_domain_cert_write_metadata "$renewal_material" letsencrypt 443 "$CERTS_DIR/letsencrypt/live/alias.example.com"
letsencrypt_source_domain_from_cert_ref owner letsencrypt/live/alias.example.com
[ "$owner" = alias.example.com ] || fail 'Renewal lookup ignored a nonstandard certificate ID'

duplicate_material="$DOMAINS_DIR/alias.example.com/certs/duplicate"
mkdir -p "$duplicate_material"
_domain_cert_write_metadata "$duplicate_material" custom 443 "$legacy_reference"
normalized=unchanged
if normalize_cert_dir normalized custom/live/alias.example.com_443 >"$TEST_ROOT/path-error" 2>&1; then fail 'Ambiguous saved certificate references were accepted'; fi
[ "$normalized" = unchanged ] || fail 'Ambiguous reference changed the output variable'
grep -Fq 'multiple managed certificate IDs' "$TEST_ROOT/path-error" || fail 'Ambiguous reference did not explain explicit owner/id resolution'
normalize_cert_dir normalized alias.example.com/public-tls
[ "$normalized" = "$alias_material" ] || fail 'Alias ambiguity affected an explicit owner/id reference'
safe_rm_rf "$duplicate_material" "$DOMAINS_DIR/alias.example.com/certs"

for unsafe_ref in custom/live/../alias.example.com_443 "$TEST_ROOT/outside/custom/live/alias.example.com_443"; do
  normalized=unchanged
  if normalize_cert_dir normalized "$unsafe_ref" >"$TEST_ROOT/path-error" 2>&1; then fail 'Saved aliases allowed an external or traversing reference'; fi
  [ "$normalized" = unchanged ] || fail 'Rejected alias changed the output variable'
done
ln -s "$TEST_ROOT/outside" "$legacy_reference"
normalized=unchanged
if normalize_cert_dir normalized custom/live/alias.example.com_443 >"$TEST_ROOT/path-error" 2>&1; then fail 'Saved alias bypassed a symlinked legacy reference'; fi
[ "$normalized" = unchanged ] || fail 'Symlink rejection changed the output variable'
safe_rm_f "$legacy_reference" "$CERTS_DIR/custom/live"
ln -s "$TEST_ROOT/outside" "$DOMAINS_DIR/alias.example.com/certs/linked"
if normalize_cert_dir normalized custom/live/alias.example.com_443 >"$TEST_ROOT/path-error" 2>&1; then fail 'Alias lookup accepted a symlinked owned directory'; fi

# Removing a declaration retains its material without allowing a later export
# to reintroduce the row. Re-adding the same declaration reuses that material.
function transaction_is_active() { return 0; }
function _domain_config_domain_selected() { return 0; }
function domain_config_certificate_option() { :; }
function add_cert() { fail 'Retained matching material was unnecessarily reissued'; }
function _domain_cert_valid_pair() { [ -f "$1/fullchain.pem" ] && [ -f "$1/privkey.pem" ]; }
material="$DOMAINS_DIR/example.com/certs/custom-443"
printf 'retained certificate fixture\n' >"$material/fullchain.pem"
printf 'retained private fixture\n' >"$material/privkey.pem"
_domain_cert_write_metadata "$material" custom 443
_domain_runtime_put "$material/certificate.csv" specification "$(_domain_cert_fingerprint custom-443 custom 443 '' '')"
mkdir -p "$TEST_ROOT/candidate/example.com/config" "$TEST_ROOT/exported"
printf 'certificate_id,provider,port_suffix,source_fullchain,source_privkey\n' >"$TEST_ROOT/candidate/example.com/config/certificates.csv"
domain_config_provision_certificates "$TEST_ROOT/candidate"
[ "$(_domain_runtime_get "$material/certificate.csv" declared)" = no ] || fail 'Omitted declaration remained active'
[ -f "$material/privkey.pem" ] || fail 'Omitted declaration destroyed retained material'
domain_config_export_certificates example.com "$TEST_ROOT/exported"
[ "$(wc -l <"$TEST_ROOT/exported/certificates.csv" | tr -d ' ')" = 1 ] || fail 'Export reintroduced omitted declaration'
[ -z "$(domain_config_certificate_dirs)" ] || fail 'Picker enumeration included retained material'
printf 'custom-443,custom,443,,\n' >>"$TEST_ROOT/candidate/example.com/config/certificates.csv"
domain_config_provision_certificates "$TEST_ROOT/candidate"
[ "$(_domain_runtime_get "$material/certificate.csv" declared)" = yes ] || fail 'Restored declaration was not activated'
grep -q '^retained private fixture$' "$material/privkey.pem" || fail 'Reactivation replaced retained material'

# A successful issuer result survives a later local failure. Retry copies that
# checked private result back into active material without issuing twice.
function add_cert() {
  local destination=""
  printf 'issued\n' >>"$TEST_ROOT/issuance_calls"
  _domain_cert_destination destination "$1" letsencrypt "$2"
  mkdir -p "$destination"
  printf 'issued certificate fixture\n' >"$destination/fullchain.pem"
  printf 'issued private fixture\n' >"$destination/privkey.pem"
}
printf 'certificate_id,provider,port_suffix,source_fullchain,source_privkey\nletsencrypt-443,letsencrypt,443,,\n' >"$TEST_ROOT/candidate/example.com/config/certificates.csv"
domain_config_provision_certificates "$TEST_ROOT/candidate"
issued="$DOMAINS_DIR/example.com/certs/letsencrypt-443"
receipt="$STATE_DIR/shared/certificate_receipts/example.com/letsencrypt-443/$(_domain_cert_fingerprint letsencrypt-443 letsencrypt 443 '' '')"
[ -f "$receipt/privkey.pem" ] || fail 'Successful issuance did not save retry material'
# Model file rollback after an unrelated local renderer failure.
safe_rm_rf "$issued" "$DOMAINS_DIR/example.com/certs"
domain_config_provision_certificates "$TEST_ROOT/candidate"
[ "$(wc -l <"$TEST_ROOT/issuance_calls" | tr -d ' ')" = 1 ] || fail 'Retry contacted the issuer a second time'
cmp -s "$issued/privkey.pem" "$receipt/privkey.pem" || fail 'Retry did not restore the issued material'
echo 'domain config certificate path checks passed.'
