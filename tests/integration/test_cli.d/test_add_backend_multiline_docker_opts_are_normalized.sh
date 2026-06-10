#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_add_backend_multiline_docker_opts_are_normalized() {
  local docker_log_file="${STATE_DIR}/docker_multiline_opts.log"
  rm -f "$docker_log_file"

  local raw_opts
  raw_opts=$'--label app=demo \\\n--env "FOO=bar baz"\n--cap-add SYS_PTRACE'

  local output status
  output="$(DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_INSPECT_STATUS=running SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend multiline-opts.test nginx:alpine 18180 http --docker-opts "$raw_opts" 2>&1)"
  status=$?

  assertEquals "add-backend with multiline docker opts should succeed" 0 "$status"
  assertStringContains "add-backend output should report backend creation" "Backend for 'multiline-opts.test'" "$output"

  local opts_file="${CONFIG_DIR}/backend_docker_opts.csv"
  local expected_line="backend:multiline-opts.test,--label app=demo --env 'FOO=bar baz' --cap-add SYS_PTRACE"
  assertTrue "backend docker opts file should exist" "[ -f '$opts_file' ]"
  assertTrue "docker opts should be normalized to a canonical single line" \
    "grep -Fxq \"$expected_line\" '$opts_file'"

  local entry_count
  entry_count="$(grep -c '^backend:multiline-opts\.test,' "$opts_file" || true)"
  assertEquals "backend docker opts should only store one row for the backend" "1" "$entry_count"

  local stored_opts stored_line
  stored_line="$(grep '^backend:multiline-opts\.test,' "$opts_file" | head -n 1 || true)"
  if [ -z "$stored_line" ] || ! csv_parse_line "$stored_line" || [ "$CSV_FIELD_COUNT" -lt 2 ]; then
    fail "Expected valid docker opts CSV row for backend:multiline-opts.test"
    return
  fi
  stored_opts="${CSV_FIELDS[1]-}"
  assertEquals "stored docker opts should not contain newlines" "$stored_opts" "${stored_opts//$'\n'/}"

  assertTrue "docker run log should include normalized tokens" \
    "grep -Fq -- '--label app=demo --env FOO=bar baz --cap-add SYS_PTRACE' '$docker_log_file'"
}
