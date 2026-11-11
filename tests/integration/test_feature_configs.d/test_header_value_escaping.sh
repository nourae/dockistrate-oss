#!/usr/bin/env bash

test_header_value_escaping() {
  run_dockistrate add-backend quote-header.test nginx:alpine 18180 http >/dev/null
  assertEquals "add-backend" 0 $?

  run_dockistrate add-header response X-Quoted 'foo "bar"' >/dev/null
  assertEquals "add-header" 0 $?
  run_dockistrate add-header response X-Echo -n >/dev/null
  assertEquals "add-header -n" 0 $?

  run_dockistrate add-backend-header quote-header.test response X-Quoted 'alpha "beta"' >/dev/null
  assertEquals "add-backend-header" 0 $?
  run_dockistrate add-backend-header quote-header.test response X-Echo -n >/dev/null
  assertEquals "add-backend-header -n" 0 $?

  assertFileContainsSubstring 'add_header X-Quoted "foo \"bar\"" always;' "${CONFIG_DIR}/nginx_conf/conf.d/custom_headers.conf"
  assertFileContainsSubstring 'add_header X-Echo "-n" always;' "${CONFIG_DIR}/nginx_conf/conf.d/custom_headers.conf"
  assertFileContainsSubstring 'quote-header.test "alpha \"beta\"";' "${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  assertFileContainsSubstring 'quote-header.test "-n";' "${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
}

function _assert_header_map_literal_entry() {
  local variable="$1" domain="$2" escaped_value="$3" maps_conf="$4"
  local map_rows="" expected_line="" matches=""
  map_rows="$(awk -v variable="$variable" '
    $0 == "map $dockistrate_backend_header_key $" variable " {" { selected=1; next }
    selected && $0 == "}" { exit }
    selected { print }
  ' "$maps_conf")"
  expected_line="$(printf '    %s "%s";' "$domain" "$escaped_value")"
  matches="$(printf '%s\n' "$map_rows" | grep -Fxc -- "$expected_line" || true)"
  assertEquals "exactly one escaped entry for ${domain} in ${variable}" 1 "$matches"
}

test_backend_header_maps_preserve_backslashes() {
  local output="" maps_conf="${CONFIG_DIR}/nginx_conf/conf.d/backend_header_maps.conf"
  local value='path C:\tmp\new; literal \n \r \t \c \x41 \101; quote "word"; breakout \"; } server { listen 19999; } #; trailing \'
  # Expected Nginx literals are handwritten, independently of the escape helper.
  local escaped='path C:\\tmp\\new; literal \\n \\r \\t \\c \\x41 \\101; quote \"word\"; breakout \\\"; } server { listen 19999; } #; trailing \\'
  local variable="" fixture_status=0

  # Seed both drafts together so this renderer regression needs only one apply.
  (
    source "$ROOT_DIR/lib/config.sh"
    source "$ROOT_DIR/lib/utils.sh"
    source "$ROOT_DIR/lib/domain_config.sh"
    local primary="$STATE_DIR/domains/literal-header.test/config"
    local dedicated="$STATE_DIR/domains/dedicated.literal-header.test/config"
    domain_config_write_template literal-header.test backend "$primary" || exit 1
    domain_config_write_template dedicated.literal-header.test dedicated "$dedicated" || exit 1
    _domain_csv_set "$primary/backend.csv" image nginx:alpine || exit 1
    _domain_csv_set "$dedicated/domain.csv" target literal-header.test || exit 1
    csv_join_row 18180 8080 http '' '' no off '' off auto >>"$primary/ports.csv" || exit 1
    csv_join_row request X-Literal "$value" >>"$primary/headers.csv" || exit 1
    csv_join_row response X-Literal "$value" >>"$primary/headers.csv" || exit 1
  ) || fixture_status=$?
  assertEquals 'seed backend and inherited dedicated-host headers' 0 "$fixture_status"
  output="$(run_dockistrate apply-domain-config --all)"
  assertEquals "apply escaped request/response headers: $output" 0 "$?"

  for variable in backend_req_x_literal backend_header_x_literal; do
    _assert_header_map_literal_entry "$variable" literal-header.test "$escaped" "$maps_conf"
    _assert_header_map_literal_entry "$variable" dedicated.literal-header.test "$escaped" "$maps_conf"
  done
  assertEquals 'header data must not create extra configuration lines' 10 "$(wc -l <"$maps_conf" | tr -d ' ')"
}
