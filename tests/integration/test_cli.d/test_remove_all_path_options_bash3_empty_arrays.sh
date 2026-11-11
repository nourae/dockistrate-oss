#!/usr/bin/env bash

test_remove_all_path_options_handles_a_single_header_set() {
  local domain="remove-all-paths-single.test"
  local backend_ports_file="${CONFIG_DIR}/backend_ports.csv"
  local include_file="${CONFIG_DIR}/nginx_conf/conf.d/path_headers/single-path-set.conf"
  local output status

  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals "seed single-path backend" 0 $?
  run_dockistrate add-port "$domain" 18180 18180 http none no >/dev/null
  assertEquals "seed single-path port" 0 $?
  run_dockistrate add-path-option "$domain" 18180 /api --headers single-path-set >/dev/null
  assertEquals "seed single path option" 0 $?
  assertTrue "single path header include should exist" "[ -f '$include_file' ]"

  output="$(run_dockistrate remove-all-path-options "$domain" 2>&1)"
  status=$?
  assertEquals "remove-all-path-options should handle a single header set" 0 "$status"
  assertStringContains "single-domain removal output" "Removed path overrides for ${domain}." "$output"
  assertFalse "single-domain path row should be removed" \
    "grep -Fq 'path,${domain},' '${backend_ports_file}'"
  assertTrue "single-domain header include should be removed" "[ ! -e '$include_file' ]"
  assertTrue "single-domain backend row should remain" \
    "grep -Fq 'backend,${domain},' '${backend_ports_file}'"
}

test_remove_all_path_options_preserves_another_domains_header_set() {
  local remove_domain="remove-all-paths-target.test"
  local keep_domain="remove-all-paths-keeper.test"
  local backend_ports_file="${CONFIG_DIR}/backend_ports.csv"
  local path_header_dir="${CONFIG_DIR}/nginx_conf/conf.d/path_headers"
  local remove_include="${path_header_dir}/target-path-set.conf"
  local keep_include="${path_header_dir}/keeper-path-set.conf"
  local output status

  run_dockistrate add-backend "$remove_domain" nginx:alpine 18181 http >/dev/null
  assertEquals "seed target backend" 0 $?
  run_dockistrate add-port "$remove_domain" 18181 18181 http none no >/dev/null
  assertEquals "seed target port" 0 $?
  run_dockistrate add-path-option "$remove_domain" 18181 /target --headers target-path-set >/dev/null
  assertEquals "seed target path option" 0 $?

  run_dockistrate add-backend "$keep_domain" nginx:alpine 18182 http >/dev/null
  assertEquals "seed keeper backend" 0 $?
  run_dockistrate add-port "$keep_domain" 18182 18182 http none no >/dev/null
  assertEquals "seed keeper port" 0 $?
  run_dockistrate add-path-option "$keep_domain" 18182 /keep --headers keeper-path-set >/dev/null
  assertEquals "seed keeper path option" 0 $?
  assertTrue "target header include should exist" "[ -f '$remove_include' ]"
  assertTrue "keeper header include should exist" "[ -f '$keep_include' ]"

  output="$(run_dockistrate remove-all-path-options "$remove_domain" 2>&1)"
  status=$?
  assertEquals "remove-all-path-options should preserve another domain" 0 "$status"
  assertFalse "target path row should be removed" \
    "grep -Fq 'path,${remove_domain},' '${backend_ports_file}'"
  assertTrue "keeper path row should remain" \
    "grep -Fq 'path,${keep_domain},' '${backend_ports_file}'"
  assertTrue "target header include should be removed" "[ ! -e '$remove_include' ]"
  assertTrue "keeper header include should remain" "[ -f '$keep_include' ]"
}
