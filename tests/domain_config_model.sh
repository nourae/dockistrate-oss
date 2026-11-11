#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done

test_root="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-domain-model.XXXXXXXX")"
trap 'rm -rf "$test_root"' EXIT
STATE_DIR="$test_root/state"
CERTS_DIR="$STATE_DIR/certs"
TMP_DIR="$STATE_DIR/tmp"
SKIP_DOCKER_CHECKS=true
INTERACTIVE=false
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$CERTS_DIR" "$TMP_DIR"
config_reset_defaults
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files

function fail_model() { echo "[Error] $*" >&2; exit 1; }
function expect_invalid_model() {
  if "$@" >"$test_root/rejected.log" 2>&1; then fail_model "Expected rejection: $*"; fi
}

candidate="$test_root/candidate"
mkdir -p "$candidate/example.com/config"
domain_config_write_template example.com backend "$candidate/example.com/config"
_domain_csv_set "$candidate/example.com/config/backend.csv" image nginx:alpine
csv_join_row 80 8080 http '' '' no off '' off auto >>"$candidate/example.com/config/ports.csv"
csv_join_row response X-Message 'Hello, "reader"' >>"$candidate/example.com/config/headers.csv"
_domain_csv_set "$candidate/example.com/config/settings.csv" http_version http2
_domain_csv_set "$candidate/example.com/config/settings.csv" client_ip_header off
_domain_csv_set "$candidate/example.com/config/settings.csv" proxy_ip_header off
csv_join_row p1 80 /api prefix 20 '' strip-prefix '' >>"$candidate/example.com/config/paths.csv"
_domain_csv_set "$candidate/example.com/config/path_options.csv" p1 websocket yes
csv_join_row rule-a 20 1 require single 403 'A reason, quoted' auto >>"$candidate/example.com/config/security_rules.csv"
csv_join_row rule-a 1 path - starts_with /private >>"$candidate/example.com/config/security_conditions.csv"
csv_join_row acl-a 1 1 l7 deny 192.0.2.3 403 >>"$candidate/example.com/config/acl.csv"
csv_join_row 1 --env >>"$candidate/example.com/config/docker_options.csv"
csv_join_row 2 'MESSAGE=hello, "world"' >>"$candidate/example.com/config/docker_options.csv"
domain_config_validate_directory example.com "$candidate/example.com/config"

mkdir -p "$candidate/other.example.com/config"
domain_config_write_template other.example.com backend "$candidate/other.example.com/config"
_domain_csv_set "$candidate/other.example.com/config/backend.csv" image nginx:alpine
csv_join_row 80 8080 http '' '' no off '' off auto >>"$candidate/other.example.com/config/ports.csv"
csv_join_row rule-b 10 1 require single 404 - auto >>"$candidate/other.example.com/config/security_rules.csv"
csv_join_row rule-b 1 method - equals DELETE >>"$candidate/other.example.com/config/security_conditions.csv"

mkdir -p "$candidate/www.example.com/config"
domain_config_write_template www.example.com dedicated "$candidate/www.example.com/config"
_domain_csv_set "$candidate/www.example.com/config/domain.csv" target example.com
_domain_csv_set "$candidate/www.example.com/config/inheritance.csv" headers no
csv_join_row response X-Own yes >>"$candidate/www.example.com/config/headers.csv"

# Runtime addresses must not be sourced from a corrupt aggregate row. Keep the
# compiler Docker-free, including missing/stale observations and legacy input.
(
  STATE_DIR="$test_root/address-state"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR" "$STATE_DIR/domains/example.com/runtime"
  printf '5\n' >"$CONFIG_DIR/state_schema_version"
  _dc_domain=example.com _dc_current_backend_ports="$BACKEND_PORTS_FILE" network="$DEFAULT_NETWORK" _dc_backend_ip=''
  observed="$STATE_DIR/domains/example.com/runtime/observed.csv"
  identity_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  identity_token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  printf '%s\n' "$STATE_BACKEND_IDENTITY_HEADER" "example.com,$identity_id,$identity_token" >"$CONFIG_DIR/backend_identity.csv"
  function docker() { : >"$test_root/compiler-docker-called"; return 1; }
  function assert_compiled_address() {
    _domain_config_compile_backend_address || fail_model 'Address compilation failed'
    [ "$_dc_backend_ip" = "$1" ] || fail_model "Expected compiled address $1, got $_dc_backend_ip"
    [ ! -e "$test_root/compiler-docker-called" ] || fail_model 'Address compilation queried Docker'
  }
  function seed_address_cache() {
    printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
    state_backend_ports_row_backend example.com 172.20.0.3:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  }
  seed_address_cache
  printf 'backend,example.com,127.0.0.999:8080,%s,,,,,,,,,,,,,,,,,\n' "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  assert_compiled_address 172.20.0.3
  printf 'container_id,ownership_token,image,image_id,state,network,address\n%s,%s,,,,%s,172.20.0.8\n' "$identity_id" "$identity_token" "$DEFAULT_NETWORK" >"$observed"
  assert_compiled_address 172.20.0.8
  # Authoritative observations also bypass malformed cache headers and quoting.
  printf 'broken cache\n"unterminated\n' >"$BACKEND_PORTS_FILE"
  assert_compiled_address 172.20.0.8
  mkdir -p "$STATE_DIR/domains/example.com/runtime/applied"
  cp "$candidate/example.com/config/"*.csv "$STATE_DIR/domains/example.com/runtime/applied/"
  before_observed_fingerprint="$(_domain_config_cache_fingerprint)"
  _domain_runtime_put "$observed" address 172.20.0.9
  assert_compiled_address 172.20.0.9
  [ "$(_domain_config_cache_fingerprint)" != "$before_observed_fingerprint" ] || fail_model 'Observation change did not invalidate cache fingerprint'
  seed_address_cache
  _domain_runtime_put "$observed" container_id cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  assert_compiled_address 172.20.0.3
  _domain_runtime_put "$observed" container_id "$identity_id"
  _domain_runtime_put "$observed" ownership_token cccccccccccccccccccccccccccccccc
  assert_compiled_address 172.20.0.3
  _domain_runtime_put "$observed" ownership_token "$identity_token"
  _domain_runtime_put "$observed" network different-net
  assert_compiled_address 172.20.0.3
  _domain_runtime_put "$observed" network "$DEFAULT_NETWORK"
  _domain_runtime_put "$observed" address 127.0.0.999
  assert_compiled_address 172.20.0.3
  mv "$observed" "$test_root/observation-target"
  ln -s "$test_root/observation-target" "$observed"
  expect_invalid_model _domain_config_cache_fingerprint
  rm "$observed"
  state_backend_ports_row_backend example.com 172.20.0.4:8080 "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  assert_compiled_address 127.0.0.1
  printf 'broken cache\n"unterminated\n' >"$BACKEND_PORTS_FILE"
  assert_compiled_address 127.0.0.1
  domain_config_validate_tree "$candidate" || fail_model 'Corrupt derived cache blocked valid source validation'
  [ ! -e "$test_root/compiler-docker-called" ] || fail_model 'Source validation queried Docker'
  printf '1\n' >"$CONFIG_DIR/state_schema_version"
  seed_address_cache
  assert_compiled_address 172.20.0.3
  printf 'backend,example.com,127.0.0.999:8080,%s,,,,,,,,,,,,,,,,,\n' "$DEFAULT_NETWORK" >>"$BACKEND_PORTS_FILE"
  expect_invalid_model _domain_config_compile_backend_address
)

# Source-only validation must not treat nonregular shared inputs as absent.
# Keep missing optional shared files valid and reject links without following
# them, even when bootstrap is bypassed by validation or an apply preview.
(
  STATE_DIR="$test_root/shared-path-state"
  _domain_config_bind_config "$STATE_DIR/config"
  mkdir -p "$CONFIG_DIR"
  printf '5\n' >"$CONFIG_DIR/state_schema_version"
  function docker() { : >"$test_root/shared-path-docker-called"; return 1; }
  domain_config_validate_tree "$candidate" || fail_model 'Missing optional shared files blocked source validation'
  for shared_file in global_settings.csv custom_headers.csv port_tls_protocols.csv port_tls_ciphers.csv access_log_fields.csv; do
    for shared_kind in directory dangling_symlink regular_symlink; do
      case "$shared_kind" in
      directory) mkdir "$CONFIG_DIR/$shared_file" ;;
      dangling_symlink) ln -s "$test_root/no-shared-source" "$CONFIG_DIR/$shared_file" ;;
      regular_symlink)
        printf 'unchanged external target\n' >"$test_root/shared-path-target"
        ln -s "$test_root/shared-path-target" "$CONFIG_DIR/$shared_file"
        ;;
      esac
      expect_invalid_model domain_config_validate_tree "$candidate"
      grep -Fq "Shared configuration must be a regular file, not a symlink: $CONFIG_DIR/$shared_file" "$test_root/rejected.log" || fail_model 'Nonregular shared input lost its path diagnostic'
      case "$shared_kind" in
      directory) rmdir "$CONFIG_DIR/$shared_file" ;;
      *) rm "$CONFIG_DIR/$shared_file" ;;
      esac
    done
  done
  [ "$(cat "$test_root/shared-path-target")" = 'unchanged external target' ] || fail_model 'Source validation changed a symlink target'
  domain_config_validate_tree "$candidate" || fail_model 'Rejected shared paths affected later source validation'
  [ ! -e "$test_root/shared-path-docker-called" ] || fail_model 'Shared input validation queried Docker'
)

domain_config_compile "$candidate" "$test_root/compiled"
grep -Fq 'port,example.com,,,,,80,8080,http,none,no,off,,off,auto' "$test_root/compiled/backend_ports.csv" || fail_model 'port compilation lost defaults'
grep -Fq 'path,example.com,,,/api,,80,,,,yes,inherit,,,,prefix,20,,strip-prefix,-,auto' "$test_root/compiled/backend_ports.csv" || fail_model 'path compilation lost options'
[ "$(sed -n '2p' "$test_root/compiled/security_rules.csv" | cut -d, -f2)" = other.example.com ] || fail_model 'global security order changed'
grep -Fq 'example.com,response,X-Message,"Hello, ""reader"""' "$test_root/compiled/backend_headers.csv" || fail_model 'quoted header roundtrip failed'
(
  _domain_config_bind_config "$test_root/compiled"
  CLIENT_IP_HEADER=X-Forwarded-For PROXY_IP_HEADER=X-Real-IP
  [ -z "$(get_backend_client_ip_header example.com)" ] || fail_model 'blank client header inherited the global default'
  [ -z "$(get_backend_proxy_ip_header example.com)" ] || fail_model 'blank proxy header inherited the global default'
)
domain_config_validate_tree "$candidate"

# Removing the last HTTP mapping leaves host associations dormant. Explicit
# paths must still be removed with their listener to avoid dangling references.
cp -R "$candidate" "$test_root/dormant"
for file in ports.csv paths.csv path_options.csv; do
  _domain_csv_schema "$file"
  printf '%s\n' "$DOMAIN_CSV_HEADER" >"$test_root/dormant/example.com/config/$file"
done
domain_config_validate_tree "$test_root/dormant"
csv_join_row p1 80 /api prefix 20 '' strip-prefix '' >>"$test_root/dormant/example.com/config/paths.csv"
expect_invalid_model domain_config_validate_tree "$test_root/dormant"

# Serialization treats CRLF, quote style, row order and absent optional files as
# equivalent without reading files as executable shell syntax.
cp -R "$candidate/example.com/config" "$test_root/equivalent"
{
  printf 'state,network,container_port,image\r\n'
  printf 'running,%s,8080,"nginx:alpine"\r\n' "$DEFAULT_NETWORK"
} >"$test_root/equivalent/backend.csv"
rm "$test_root/equivalent/mtls.csv"
[ "$(domain_config_canonicalize "$candidate/example.com/config")" = "$(domain_config_canonicalize "$test_root/equivalent")" ] || fail_model 'semantic canonicalization changed with formatting'
cp -R "$candidate/example.com/config" "$test_root/empty-file"
: >"$test_root/empty-file/headers.csv"
expect_invalid_model domain_config_validate_directory example.com "$test_root/empty-file"
expect_invalid_model domain_config_canonicalize "$test_root/empty-file"
_domain_csv_set "$test_root/equivalent/settings.csv" client_ip_header ''
[ "$(domain_config_canonicalize "$candidate/example.com/config")" != "$(domain_config_canonicalize "$test_root/equivalent")" ] || fail_model 'blank inherited header became explicit off'

# End-to-end adapter export from compiled runtime retains every capability.
for domain in example.com other.example.com www.example.com; do
  mkdir -p "$STATE_DIR/domains/$domain/runtime/applied"
  cp "$candidate/$domain/config/"*.csv "$STATE_DIR/domains/$domain/runtime/applied/"
done
printf 'domain,image,state\nexample.com,nginx:alpine,running\n' >"$test_root/details.csv"
(
  _domain_config_bind_config "$test_root/compiled"
  domain_config_export_domain example.com "$test_root/exported" "$test_root/details.csv"
)
domain_config_validate_directory example.com "$test_root/exported"
grep -Fq 'X-Message,"Hello, ""reader"""' "$test_root/exported/headers.csv" || fail_model 'export lost quoted header'
grep -Fq 'MESSAGE=hello, ""world""' "$test_root/exported/docker_options.csv" || fail_model 'export lost argument boundaries'
[ "$(domain_config_canonicalize "$candidate/example.com/config")" = "$(domain_config_canonicalize "$test_root/exported")" ] || fail_model 'export changed stable IDs, explicit orders or semantic defaults'

# Moving global ordinals retains row identity and redistributes the prior order
# slots, including sparse user-written order numbers, across domain files.
{
  sed -n '1p' "$test_root/compiled/security_rules.csv"
  sed -n '3p' "$test_root/compiled/security_rules.csv"
  sed -n '2p' "$test_root/compiled/security_rules.csv"
} >"$test_root/moved-rules.csv"
cp "$test_root/moved-rules.csv" "$test_root/compiled/security_rules.csv"
(
  _domain_config_bind_config "$test_root/compiled"
  domain_config_export_domain example.com "$test_root/moved-example" "$test_root/details.csv"
  domain_config_export_domain other.example.com "$test_root/moved-other"
)
grep -Fq 'rule-a,10,' "$test_root/moved-example/security_rules.csv" || fail_model 'move lost first rule identity/order'
grep -Fq 'rule-b,20,' "$test_root/moved-other/security_rules.csv" || fail_model 'move lost second rule identity/order'

# Adapter order remains faithful if a new row occurs before an existing row.
# Reuse sparse slots without changing the identities of the known rules.
(
  DOMAINS_DIR="$test_root/identity-domains"
  mkdir -p "$DOMAINS_DIR/example.com/runtime/applied"
  printf 'rule_id,order,enabled,scope,action,ip_value,status_code\noriginal,10,1,l7,deny,192.0.2.1,403\n' >"$DOMAINS_DIR/example.com/runtime/applied/acl.csv"
  SECURITY_IP_RULES_FILE="$test_root/interleaved-acl.csv"
  printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_FILE"
  csv_join_row 1 example.com l7 deny 192.0.2.2 403 >>"$SECURITY_IP_RULES_FILE"
  csv_join_row 1 example.com l7 deny 192.0.2.1 403 >>"$SECURITY_IP_RULES_FILE"
  _domain_config_export_identity_prepare acl
  [ "${_dc_export_orders_by_order[*]}" = '10 11' ] || fail_model 'new rule changed effective global order'
  [ "${_dc_export_ids_by_order[1]}" = original ] || fail_model 'interleaved rule changed existing identity'
)

_domain_csv_set "$candidate/example.com/config/mtls.csv" enabled yes
_domain_csv_set "$candidate/example.com/config/mtls.csv" directory ''
domain_config_compile "$candidate" "$test_root/blank-mtls"
grep -Fq "example.com,${STATE_DIR}/domains/example.com/mtls" "$test_root/blank-mtls/backend_mtls.csv" || fail_model 'blank mTLS directory did not use owned default'
_domain_csv_write_header "$candidate/example.com/config/mtls.csv"

cp "$candidate/other.example.com/config/security_rules.csv" "$test_root/rules.saved"
sed_in_place 's/rule-b,10,/rule-b,20,/' "$candidate/other.example.com/config/security_rules.csv"
expect_invalid_model domain_config_compile "$candidate" "$test_root/duplicate-order"
cp "$test_root/rules.saved" "$candidate/other.example.com/config/security_rules.csv"
csv_join_row rule-missing 1 path - equals / >>"$candidate/example.com/config/security_conditions.csv"
expect_invalid_model domain_config_validate_directory example.com "$candidate/example.com/config"
sed_in_place '/^rule-missing,/d' "$candidate/example.com/config/security_conditions.csv"

cp "$candidate/example.com/config/ports.csv" "$test_root/ports.saved"
csv_join_row 443 8080 https missing.example.com cert1 no off '' off auto >>"$candidate/example.com/config/ports.csv"
expect_invalid_model domain_config_compile "$candidate" "$test_root/missing-certificate"
cp "$test_root/ports.saved" "$candidate/example.com/config/ports.csv"

ln -s "$candidate/example.com/config/headers.csv" "$test_root/equivalent/extra.csv"
expect_invalid_model domain_config_validate_directory example.com "$test_root/equivalent"
expect_invalid_model domain_config_canonicalize "$test_root/equivalent"
rm "$test_root/equivalent/extra.csv"
printf 'unrecognized settings file\n' >"$test_root/equivalent/settings.txt"
expect_invalid_model domain_config_canonicalize "$test_root/equivalent"
rm "$test_root/equivalent/settings.txt"
csv_join_row unknown value >>"$test_root/equivalent/backend.csv"
expect_invalid_model domain_config_validate_directory example.com "$test_root/equivalent"
_domain_csv_set "$candidate/example.com/config/inheritance.csv" headers no
expect_invalid_model domain_config_validate_directory example.com "$candidate/example.com/config"
_domain_csv_write_header "$candidate/example.com/config/inheritance.csv"
_domain_csv_set "$candidate/example.com/config/mtls.csv" directory "$CERTS_DIR/mtls/example.com"
expect_invalid_model domain_config_validate_directory example.com "$candidate/example.com/config"
_domain_csv_write_header "$candidate/example.com/config/mtls.csv"
cp -R "$candidate/www.example.com/config" "$test_root/duplicate-defaults"
_domain_csv_set "$test_root/duplicate-defaults/inheritance.csv" paths yes
sed -n '2p' "$test_root/duplicate-defaults/inheritance.csv" >>"$test_root/duplicate-defaults/inheritance.csv"
expect_invalid_model domain_config_validate_source www.example.com "$test_root/duplicate-defaults"

# Certificate-only owners can satisfy future HTTPS mappings before issuance;
# HTTP/3 reserves the same UDP listener as its selected HTTPS port.
mkdir -p "$candidate/certs.example.com/config"
domain_config_write_template certs.example.com certificate-only "$candidate/certs.example.com/config"
csv_join_row web selfsigned 443 '' '' >>"$candidate/certs.example.com/config/certificates.csv"
csv_join_row 443 8080 https certs.example.com web no off '' off auto >>"$candidate/example.com/config/ports.csv"
_domain_csv_set "$candidate/example.com/config/ports.csv" 443 https http3_enabled on
domain_config_validate_tree "$candidate"
csv_join_row 443 8080 udp '' '' no off '' off auto >>"$candidate/other.example.com/config/ports.csv"
expect_invalid_model domain_config_compile "$candidate" "$test_root/quic-conflict"
cp "$candidate/certs.example.com/config/certificates.csv" "$test_root/certificates-before-unknown"
expect_invalid_model _domain_csv_set "$candidate/certs.example.com/config/certificates.csv" nonexistent source_fullchain /tmp/missing
cmp -s "$test_root/certificates-before-unknown" "$candidate/certs.example.com/config/certificates.csv" || fail_model 'Unknown certificate update changed declarations'

# Managed uploaded material remains reusable after its original import files
# disappear. Validation and unrelated applies must not try to import it again.
reuse_candidate="$test_root/reuse-candidate"
reuse_config="$reuse_candidate/reuse.example.com/config"
reuse_material="$STATE_DIR/domains/reuse.example.com/certs/upload"
domain_config_write_template reuse.example.com certificate-only "$reuse_config"
csv_join_row upload custom 443 '' '' >>"$reuse_config/certificates.csv"
_domain_csv_set "$reuse_config/certificates.csv" upload source_fullchain "$test_root/removed-upload/fullchain.pem"
_domain_csv_set "$reuse_config/certificates.csv" upload source_privkey "$test_root/removed-upload/privkey.pem"
expect_invalid_model domain_config_validate_directory reuse.example.com "$reuse_config"
mkdir -p "$reuse_material"
openssl req -x509 -nodes -days 1 -newkey rsa:2048 -keyout "$reuse_material/privkey.pem" -out "$reuse_material/fullchain.pem" -subj /CN=reuse.example.com >/dev/null 2>&1
_domain_cert_write_metadata "$reuse_material" custom 443
_domain_runtime_put "$reuse_material/certificate.csv" source_fullchain "$test_root/removed-upload/fullchain.pem"
_domain_runtime_put "$reuse_material/certificate.csv" source_privkey "$test_root/removed-upload/privkey.pem"
domain_config_validate_directory reuse.example.com "$reuse_config"
before_certificate="$(cksum <"$reuse_material/fullchain.pem")"
(
  DOMAIN_CONFIG_SELECTED_FILE=""
  function transaction_is_active() { return 0; }
  function add_cert() { fail_model 'unchanged managed certificate was reimported'; }
  domain_config_provision_certificates "$reuse_candidate"
)
[ "$(cksum <"$reuse_material/fullchain.pem")" = "$before_certificate" ] || fail_model 'managed certificate changed during reuse'

# A role change cannot orphan a container or silently adopt a host association.
# Explicit removal still permits retaining a certificate-only owner, and an
# existing certificate-only owner can gain its first backend.
(
  _domain_config_bind_config "$test_root/compiled"
  role_tree="$test_root/role-transitions"
  domain_config_write_template example.com certificate-only "$role_tree/example.com/config"
  expect_invalid_model domain_config_compile "$role_tree" "$test_root/rejected-role"
  domain_config_write_template www.example.com backend "$test_root/host-role/www.example.com/config"
  _domain_csv_set "$test_root/host-role/www.example.com/config/backend.csv" image nginx:alpine
  expect_invalid_model domain_config_compile "$test_root/host-role" "$test_root/rejected-host-role"
  domain_config_write_template reuse.example.com backend "$test_root/cert-role/reuse.example.com/config"
  _domain_csv_set "$test_root/cert-role/reuse.example.com/config/backend.csv" image nginx:alpine
  mkdir -p "$STATE_DIR/domains/reuse.example.com/runtime/applied"
  cp "$reuse_config/domain.csv" "$STATE_DIR/domains/reuse.example.com/runtime/applied/domain.csv"
  domain_config_compile "$test_root/cert-role" "$test_root/accepted-cert-role"
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  domain_config_compile "$role_tree" "$test_root/explicit-removal-role"
)

# Migration inventory includes domain-owned state even when its primary row
# is missing, so preflight can reject orphan rows instead of dropping them.
(
  STATE_DIR="$test_root"
  _domain_config_bind_config "$test_root/inventory"
  CERTS_DIR="$test_root/inventory-certs"
  mkdir -p "$CONFIG_DIR" "$CERTS_DIR/mtls/ca-only.example.com"
  state_csv_ensure_all_state_files
  csv_join_row docker-only.example.com '--memory 64m' >>"$BACKEND_DOCKER_OPTS_FILE"
  csv_join_row dedicated-only.example.com no yes yes yes yes >>"$CONFIG_DIR/dedicated_host_inheritance.csv"
  inventory="$(_domain_config_legacy_domains)"
  for domain in docker-only.example.com dedicated-only.example.com ca-only.example.com; do
    printf '%s\n' "$inventory" | grep -Fxq "$domain" || fail_model "migration inventory omitted $domain"
  done
  csv_join_row 'invalid owner key' '--memory 64m' >>"$BACKEND_DOCKER_OPTS_FILE"
  expect_invalid_model _domain_config_legacy_domains
)

echo '[tests] domain_config_model.sh: PASS'
