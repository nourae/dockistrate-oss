#!/usr/bin/env bash
# Model and runtime paths are consumed by sourced modules.
# shellcheck disable=SC2034
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for module in config utils logging backends nginx nginx_directives ports certs backups global_settings http_version tls mtls headers security_rules domain_config; do
  # shellcheck disable=SC1090
  source "$ROOT_DIR/lib/$module.sh"
done
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-numeric.XXXXXXXX")"
TEST_WORK="$(cd "$TEST_WORK" && pwd -P)"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"; DOMAINS_DIR="$STATE_DIR/domains"; TMP_DIR="$STATE_DIR/tmp"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR" "$TMP_DIR"
config_reset_defaults
SKIP_DOCKER_CHECKS=true INTERACTIVE=false
state_csv_ensure_all_state_files
function fail_test() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
function reject_test() { if ( "$@" ) >"$TEST_WORK/rejected" 2>&1; then fail_test "Unexpected success: $*"; fi; }
function _config_begin_transaction_if_needed() { :; }
function _config_end_transaction_if_started() { :; }
function create_backup() { :; }
function update_nginx_config_for_security_change() { :; }
function update_nginx_config() { :; }
function log_msg() { :; }
config="$DOMAINS_DIR/example.com/config"
applied="$DOMAINS_DIR/example.com/runtime/applied"
domain_config_write_template example.com backend "$config"
_domain_csv_set "$config/backend.csv" image nginx:alpine
csv_join_row 80 8080 http '' '' no off '' off auto >>"$config/ports.csv"
csv_join_row path-a 80 /api prefix 10 upstream.example.com:81 none '' >>"$config/paths.csv"
domain_config_validate_source example.com "$config"
canonical="$(domain_config_canonicalize "$config")"
_domain_csv_write_header "$config/ports.csv"
csv_join_row 00080 08080 http '' '' no off '' off auto >>"$config/ports.csv"
_domain_csv_write_header "$config/paths.csv"
csv_join_row path-a 080 /api prefix 010 upstream.example.com:0081 none '' >>"$config/paths.csv"
cp "$config/ports.csv" "$TEST_WORK/original-ports"
cp "$config/paths.csv" "$TEST_WORK/original-paths"
domain_config_validate_source example.com "$config"
_domain_config_validate_source_tree "$DOMAINS_DIR"
[ "$(domain_config_canonicalize "$config")" = "$canonical" ] || fail_test 'Padded numbers created a semantic pending edit'
cmp -s "$config/ports.csv" "$TEST_WORK/original-ports" && cmp -s "$config/paths.csv" "$TEST_WORK/original-paths" || fail_test 'Reading rewrote the editable draft'
# Both spellings represent the same listener and must not bypass duplicate checks.
csv_join_row 80 8080 http '' '' no off '' off auto >>"$config/ports.csv"
reject_test domain_config_validate_source example.com "$config"
cp "$TEST_WORK/original-ports" "$config/ports.csv"
# Across domains, zero padding must not hide a TCP/HTTP listener conflict.
other="$DOMAINS_DIR/other.example.com/config"
domain_config_write_template other.example.com backend "$other"
_domain_csv_set "$other/backend.csv" image nginx:alpine
csv_join_row 080 80 tcp '' '' no off '' off auto >>"$other/ports.csv"
reject_test _domain_config_validate_source_tree "$DOMAINS_DIR"
rm -rf "$DOMAINS_DIR/other.example.com"
# A staged CLI field update finds the same logical record and publishes canonical numbers.
_domain_csv_set "$config/ports.csv" 080 http websocket yes
[ "$(_domain_csv_rows "$config/ports.csv")" = '80,8080,http,,,yes,off,,off,auto' ] || fail_test 'Setter missed or duplicated padded port identity'
[ "$(domain_config_port_option "$config" 00080 http websocket no)" = yes ] || fail_test 'Padded port lookup lost its option'

# Shared TLS settings use the same numeric key, including reordered old input.
printf 'tls_protocols,listen_port\nTLSv1.2,0443\n' >"$PORT_TLS_PROTOCOLS_FILE"
[ "$(get_port_tls_protocols 443)" = TLSv1.2 ] || fail_test 'Lost existing padded TLS override'
state_csv_upsert_two_col_value "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" 00443 TLSv1.3
[ "$(state_csv_get_two_col_value "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" 0443 '')" = TLSv1.3 ] || fail_test 'TLS update missed numeric identity'
[ "$(wc -l <"$PORT_TLS_PROTOCOLS_FILE" | tr -d ' ')" = 2 ] || fail_test 'TLS update duplicated record'
state_csv_delete_two_col_key "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER" 0443
[ "$(wc -l <"$PORT_TLS_PROTOCOLS_FILE" | tr -d ' ')" = 1 ] || fail_test 'TLS removal missed padded key'
printf '%s\n' "$STATE_PORT_TLS_PROTOCOLS_HEADER" '443,TLSv1.2' '0443,TLSv1.3' >"$PORT_TLS_PROTOCOLS_FILE"
reject_test state_csv_contents "$PORT_TLS_PROTOCOLS_FILE" "$STATE_PORT_TLS_PROTOCOLS_HEADER"

# Padded selectors match existing port/path records rather than another port.
printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
state_backend_ports_row_backend example.com 127.0.0.1:80 dockistrate-net >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_port example.com 080 8080 http none no off '' off auto >>"$BACKEND_PORTS_FILE"
state_backend_ports_row_path example.com /api '' 080 inherit inherit '' prefix 10 '' none - auto >>"$BACKEND_PORTS_FILE"
_require_port_mapping_for_path example.com 00080
remove_path_option example.com 00080 /api >"$TEST_WORK/path-remove"
[ "$(wc -l <"$BACKEND_PORTS_FILE" | tr -d ' ')" = 3 ] || fail_test 'Padded path removal missed its port'
set_port_redirect example.com 00080 on 308:0443 >"$TEST_WORK/redirect"
line="$(sed -n '3p' "$BACKEND_PORTS_FILE")"; state_backend_ports_parse_line "$line"
[ "$STATE_BP_LISTEN_PORT" = 80 ] && [ "$STATE_BP_REDIRECT_CODE" = 308:443 ] || fail_test 'Redirect port identity was not normalized'

# Exercise the actual update command, including its direct-source text picker.
# Only transaction/proxy side effects are stubbed; selection and CSV rewrites are real.
(
  function begin_transaction() { :; }
  function end_transaction_success() { :; }
  update_port_mapping example.com 00080 --container-port 0081 --ws yes >"$TEST_WORK/port-update"
  line="$(sed -n '3p' "$BACKEND_PORTS_FILE")"; state_backend_ports_parse_line "$line"
  [ "$STATE_BP_LISTEN_PORT" = 80 ] && [ "$STATE_BP_UPSTREAM_PORT" = 81 ] && [ "$STATE_BP_WS" = yes ] || fail_test 'Port update missed decimal selector or replacement value'
  printf '%s\n' "$STATE_BACKEND_PORTS_HEADER" >"$BACKEND_PORTS_FILE"
  state_backend_ports_row_backend example.com 127.0.0.1:80 dockistrate-net >>"$BACKEND_PORTS_FILE"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    state_backend_ports_row_port example.com "$((8000 + i))" 80 http none no off '' off auto >>"$BACKEND_PORTS_FILE"
  done
  INTERACTIVE=true
  unset -f choose_option || true
  function prompt_input() { printf -v "$1" '%s' "${PICKER_CHOICE:-010}"; }
  update_port_mapping example.com --ws yes >"$TEST_WORK/port-picker"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    line="$(sed -n "$((i + 2))p" "$BACKEND_PORTS_FILE")"; state_backend_ports_parse_line "$line"
    expected=no; [ "$i" -ne 10 ] || expected=yes
    [ "$STATE_BP_WS" = "$expected" ] || fail_test "Text picker modified mapping $i for choice 010"
  done
  cp "$BACKEND_PORTS_FILE" "$TEST_WORK/before-invalid-choice"
  PICKER_CHOICE=020
  reject_test update_port_mapping example.com --ws no
  cmp -s "$BACKEND_PORTS_FILE" "$TEST_WORK/before-invalid-choice" || fail_test 'Out-of-range text selection changed mappings'
)

# Preserve stable IDs while the displayed global positions are selected in decimal.
_dc_export_ids_by_order=()
mkdir -p "$applied"
_domain_config_copy_inputs "$config" "$applied"
for family in rule acl; do
  for operation in move remove; do
    _domain_csv_write_header "$applied/acl.csv"
    _domain_csv_write_header "$applied/security_rules.csv"
    _domain_csv_write_header "$applied/security_conditions.csv"
    printf '%s\n' "$STATE_SECURITY_RULES_HEADER" >"$SECURITY_RULES_DB"
    printf '%s\n' "$STATE_SECURITY_IP_RULES_HEADER" >"$SECURITY_IP_RULES_DB"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      csv_join_row "acl-$i" "$i" 1 l7 deny "203.0.113.$i" 403 >>"$applied/acl.csv"
      csv_join_row "rule-$i" "$i" 1 block single 403 - auto >>"$applied/security_rules.csv"
      csv_join_row "rule-$i" 1 header X-Case equals "blocked-$i" >>"$applied/security_conditions.csv"
      csv_join_row 1 example.com l7 deny "203.0.113.$i" 403 >>"$SECURITY_IP_RULES_DB"
      _sr_write_db_line_with_action block 1 example.com single 403 1 - auto header X-Case equals "blocked-$i" >>"$SECURITY_RULES_DB"
    done
    DOMAIN_CONFIG_MUTATION_COMMAND="$operation-security-rule"; DOMAIN_CONFIG_IDENTITY_ARG1=010; DOMAIN_CONFIG_IDENTITY_ARG2=01
    if [ "$family" = rule ]; then
      if [ "$operation" = move ]; then move_security_rule 010 01; else remove_security_rule 010; fi
    else
      DOMAIN_CONFIG_MUTATION_COMMAND="$operation-acl"
      if [ "$operation" = move ]; then DOMAIN_CONFIG_MUTATION_COMMAND=move-acl-rule; move_security_ip_rule 010 01; else remove_security_ip 010; fi
    fi >"$TEST_WORK/policy"
    _domain_config_export_identity_prepare "$family"
    expected=10; [ "$operation" != remove ] || expected=9
    [ "${#_dc_export_ids_by_order[@]}" -eq "$expected" ] || fail_test 'Export lost row identities'
    for ((i = 0; i < expected; i++)); do
      position=$((i + 1))
      if [ "$operation" = move ]; then position="$i"; [ "$i" -ne 0 ] || position=10; fi
      [ "${_dc_export_ids_by_order[i]}" = "$family-$position" ] || fail_test "Wrong stable ID after $family $operation"
    done
  done
done
printf '[PASS] Numeric domain/TLS/port identities and global rule IDs remain consistent\n'
