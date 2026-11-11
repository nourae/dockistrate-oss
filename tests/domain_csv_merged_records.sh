#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
for module in logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-csv-merged.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; CERTS_DIR="$STATE_DIR/certs"; TMP_DIR="$STATE_DIR/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
SKIP_DOCKER_CHECKS=true INTERACTIVE=false
_save_config_write_rows >"$GLOBAL_SETTINGS_FILE"
state_csv_ensure_all_state_files

function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function reject_test() {
  if "$@" >"$TEST_WORK/rejected" 2>&1; then fail_test "Unexpected success: $*"; fi
}

config="$TEST_WORK/domains/example.com/config"
domain_config_write_template example.com backend "$config"
_domain_csv_set "$config/backend.csv" image nginx:alpine
[ "$(domain_config_get "$config" domain.csv schema_version)" = 5 ] || fail_test 'Template schema is stale'
[ ! -e "$config/port_options.csv" ] && [ ! -e "$config/certificate_options.csv" ] || fail_test 'Template retained split tables'
[ "$(head -n 1 "$config/ports.csv")" = 'listen_port,upstream_port,protocol,certificate_owner,certificate_id,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc' ] || fail_test 'Wrong listener header'
[ "$(head -n 1 "$config/certificates.csv")" = 'certificate_id,provider,port_suffix,source_fullchain,source_privkey' ] || fail_test 'Wrong certificate header'

# Optional listener cells have the same defaults after consolidation. Reading
# quoted, reordered CRLF records must neither change meaning nor rewrite drafts.
csv_join_row 80 8080 http '' '' no off '' off auto >>"$config/ports.csv"
domain_config_validate_source example.com "$config"
canonical="$(domain_config_canonicalize "$config")"
printf '"protocol",listen_port,upstream_port,certificate_id,certificate_owner,alt_svc,http3_enabled,redirect_code,redirect_enabled,websocket\r\nhttp,80,8080,,,,,,,\r\n' >"$config/ports.csv"
cp "$config/ports.csv" "$TEST_WORK/original"
domain_config_validate_source example.com "$config"
[ "$(domain_config_canonicalize "$config")" = "$canonical" ] || fail_test 'Blank listener defaults differ from explicit defaults'
cmp -s "$config/ports.csv" "$TEST_WORK/original" || fail_test 'Reading rewrote listener source'
_domain_csv_set "$config/ports.csv" 80 http websocket yes
[ "$(domain_config_port_option "$config" 80 http websocket)" = yes ] || fail_test 'Named listener edit failed'

# Identity is the listen port plus protocol, not the first two columns. Both
# transports can share a numeric port without modifying each other.
_domain_csv_write_header "$config/ports.csv"
csv_join_row 9000 8080 tcp '' '' '' '' '' '' '' >>"$config/ports.csv"
csv_join_row 9000 8081 udp '' '' '' '' '' '' '' >>"$config/ports.csv"
_domain_csv_set "$config/ports.csv" 9000 tcp upstream_port 8082
[ "$(_domain_csv_entity_field "$config/ports.csv" upstream_port '' 9000 tcp)" = 8082 ] || fail_test 'TCP row not updated'
[ "$(_domain_csv_entity_field "$config/ports.csv" upstream_port '' 9000 udp)" = 8081 ] || fail_test 'UDP row changed with TCP edit'
cp "$config/ports.csv" "$TEST_WORK/before-missing"
reject_test _domain_csv_set "$config/ports.csv" 9999 tcp websocket yes
cmp -s "$config/ports.csv" "$TEST_WORK/before-missing" || fail_test 'Missing record edit changed source'
reject_test _domain_csv_set "$config/ports.csv" 9000 tcp protocol udp
cmp -s "$config/ports.csv" "$TEST_WORK/before-missing" || fail_test 'Identity edit changed source'
csv_join_row 9000 8888 tcp '' '' '' '' '' '' '' >>"$config/ports.csv"
reject_test domain_config_validate_source example.com "$config"
cp "$TEST_WORK/before-missing" "$config/ports.csv"

# Quoted import filenames remain single cells and part of the stable issuance
# fingerprint. An absent upload location is valid while reviewing a draft.
cert_path="$TEST_WORK/import, cert.pem"; key_path="$TEST_WORK/import, key.pem"
csv_join_row imported custom 443 "$cert_path" "$key_path" >>"$config/certificates.csv"
[ "$(domain_config_certificate_option "$config" imported source_fullchain)" = "$cert_path" ] || fail_test 'Import comma was split'
domain_config_validate_source example.com "$config"
fingerprint="$(_domain_cert_fingerprint imported custom 443 "$cert_path" "$key_path")"
_domain_csv_set "$config/certificates.csv" imported source_privkey "$TEST_WORK/new, key.pem"
[ "$(domain_config_certificate_option "$config" imported source_privkey)" = "$TEST_WORK/new, key.pem" ] || fail_test 'Named certificate edit failed'
[ "$(_domain_cert_fingerprint imported custom 443 "$cert_path" "$(domain_config_certificate_option "$config" imported source_privkey)")" != "$fingerprint" ] || fail_test 'Changed import source did not affect fingerprint'
_domain_csv_set "$config/certificates.csv" imported source_privkey ''
reject_test domain_config_validate_source example.com "$config"
_domain_csv_set "$config/certificates.csv" imported source_privkey "$key_path"
_domain_csv_set "$config/certificates.csv" imported provider selfsigned
reject_test domain_config_validate_source example.com "$config"
_domain_csv_set "$config/certificates.csv" imported provider custom
cp "$config/certificates.csv" "$TEST_WORK/before-missing-cert"
reject_test _domain_csv_set "$config/certificates.csv" missing source_fullchain "$cert_path"
cmp -s "$config/certificates.csv" "$TEST_WORK/before-missing-cert" || fail_test 'Missing certificate edit changed source'

# Current sources reject the obsolete tables, even when they are header-only.
printf '%s\n' 'listen_port,protocol,websocket,redirect_enabled,redirect_code,http3_enabled,alt_svc' >"$config/port_options.csv"
reject_test domain_config_validate_source example.com "$config"
reject_test domain_config_canonicalize "$config"
rm "$config/port_options.csv"
printf '%s\n' 'certificate_id,source_fullchain,source_privkey' >"$config/certificate_options.csv"
reject_test domain_config_validate_source example.com "$config"
rm "$config/certificate_options.csv"

# Listener export and compile preserve every option without a second table.
_domain_csv_write_header "$config/ports.csv"
_dc_domain=example.com; _dc_destination="$config"
row="$(state_backend_ports_row_port example.com 443 8080 https example.com/imported yes on 308 on off)"
csv_parse_line "$row"
_domain_config_export_backend_row 1 "${CSV_FIELDS[@]}"
_dc_config="$config"; _dc_output="$TEST_WORK/compiled"; mkdir -p "$_dc_output"
: >"$_dc_output/backend_ports.csv"
_domain_csv_read "$config/ports.csv" _domain_config_compile_port
[ "$(cat "$_dc_output/backend_ports.csv")" = "$row" ] || fail_test 'Listener options changed during round trip'
domain_config_validate_source example.com "$config"
printf '[PASS] merged listener and certificate records\n'
