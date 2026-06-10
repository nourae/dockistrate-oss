#!/usr/bin/env bash

function _seed_status_backend() {
  local domain="${1:-status.test}"
  run_dockistrate add-backend "$domain" nginx:alpine 18180 http --no-expose >/dev/null
}

test_status_shows_dashboard_runtime_and_backup_lines() {
  local domain="status.test"
  local full_marker="${BACKUP_DIR}/last_full_backup.txt"
  local post_marker="${BACKUP_DIR}/last_post_backup.txt"
  _seed_status_backend "$domain"
  assertEquals "seed backend for status dashboard" 0 $?

  mkdir -p "$BACKUP_DIR"
  printf '%s\n' "${BACKUP_DIR}/20260312_000000_full_status_test.tar.gz" >"$full_marker"
  printf '%s\n' "${BACKUP_DIR}/20260312_000001_post_status_test.tar.gz" >"$post_marker"

  local output status
  output="$(run_dockistrate status)"
  status=$?

  assertEquals "status dashboard should succeed" 0 "$status"
  assertStringContains "status shows packet capture state" "Packet Capture: inactive" "$output"
  assertStringContains "status shows tls decrypt state" "TLS Decrypt Capture: off" "$output"
  assertStringContains "status shows auto backup state" "Auto Backups: on" "$output"
  assertStringContains "status shows backup retention" "Backup Retention: forever" "$output"
  assertStringContains "status shows backup compression" "Backup Compression: on" "$output"
  assertStringContains "status shows latest full backup" "Latest Full Backup: 20260312_000000_full_status_test.tar.gz" "$output"
  assertStringContains "status shows latest post backup" "Latest Post-Change Backup: 20260312_000001_post_status_test.tar.gz" "$output"
  assertStringContains "status backend summary shows state column" "Domain               | State" "$output"
  local escaped_domain="${domain//./\\.}"
  assertTrue "status backend row should report missing runtime container" \
    "printf '%s' \"$output\" | grep -Eq '^${escaped_domain}[[:space:]]*\\|[[:space:]]*missing[[:space:]]*\\|'"
  assertTrue "status should stay lean without access log fields" \
    "! printf '%s' \"$output\" | grep -Fq '=== Access Log Fields ==='"
  assertTrue "status should stay lean without certificates section" \
    "! printf '%s' \"$output\" | grep -Fq '=== Certificates ==='"
}

test_status_shows_active_capture_and_tls_decrypt_when_seeded() {
  local tls_state_file="${CONFIG_DIR}/capture_tls_decrypt.state"
  local keylog_dir="${CAPTURE_DIR}/tls-keys"
  local keylog_file="${keylog_dir}/tlskeys_test.log"
  mkdir -p "$BACKUP_DIR" "$keylog_dir"
  : >"$keylog_file"
  cat >"$tls_state_file" <<EOF
enabled=true
keylog_file=${keylog_file}
started_at=2026-03-12T12:00:00+0200
EOF
  rm -f "${BACKUP_DIR}/last_full_backup.txt" "${BACKUP_DIR}/last_post_backup.txt"

  local output status
  output="$(DOCKER_MOCK_PS_NAMES='nginx-capture' run_dockistrate status)"
  status=$?

  assertEquals "status should succeed with active capture state" 0 "$status"
  assertStringContains "status shows active packet capture" "Packet Capture: active" "$output"
  assertStringContains "status shows tls decrypt enabled" "TLS Decrypt Capture: on" "$output"
  assertStringContains "status shows missing full backup marker" "Latest Full Backup: [None]" "$output"
  assertStringContains "status shows missing post backup marker" "Latest Post-Change Backup: [None]" "$output"
}

test_status_all_shows_extended_sections() {
  local domain="status-all.test"
  local backend_opts_file="${CONFIG_DIR}/backend_docker_opts.csv"
  _seed_status_backend "$domain"
  assertEquals "seed backend for status-all" 0 $?

  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "key,docker_options" >"$backend_opts_file"
  printf '%s\n' "backend:${domain},--memory=96m --restart=on-failure:3" >>"$backend_opts_file"

  local output status
  output="$(run_dockistrate status-all)"
  status=$?

  assertEquals "status-all should succeed" 0 "$status"
  assertStringContains "status-all shows server tokens" "Server Tokens: off" "$output"
  assertStringContains "status-all shows access log section" "=== Access Log Fields ===" "$output"
  assertStringContains "status-all shows default log field output" '1:  $realip_remote_addr' "$output"
  assertStringContains "status-all shows backend docker opts section" "=== Backend Docker Opts ===" "$output"
  assertStringContains "status-all shows backend docker opts row" "--memory=96m --restart=on-failure:3" "$output"
  assertStringContains "status-all shows path options section" "=== Path Options ===" "$output"
  assertStringContains "status-all shows certificates section" "=== Certificates ===" "$output"
}
