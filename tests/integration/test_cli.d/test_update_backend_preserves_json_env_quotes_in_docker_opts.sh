#!/usr/bin/env bash

# shellcheck source=lib/utils/csv.sh
source "${ROOT_DIR}/lib/utils/csv.sh"

test_update_backend_preserves_json_env_quotes_in_docker_opts() {
  local domain="json-opts-update.test"
  local cname="backend-${domain}"
  local docker_log_file="${STATE_DIR}/docker_json_env_opts_update.log"
  local raw_opts='-e ELASTICSEARCH_HOSTS=["http://elasticsearch:9200"] --label app=kibana'
  local expected_opts="-e 'ELASTICSEARCH_HOSTS=[\"http://elasticsearch:9200\"]' --label app=kibana"
  rm -f "$docker_log_file"

  local output status
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" SKIP_DOCKER_CHECKS=false \
    run_dockistrate add-backend "$domain" nginx:alpine 5601 http --docker-opts "$raw_opts" --no-expose 2>&1)"
  status=$?
  assertEquals "setup add-backend with JSON env docker opts should succeed" 0 "$status"

  : >"$docker_log_file"
  output="$(DOCKER_MOCK_INSPECT_STATUS=running DOCKER_MOCK_LOG_FILE="$docker_log_file" DOCKER_MOCK_PS_NAMES="$cname" SKIP_DOCKER_CHECKS=false \
    run_dockistrate update-backend "$domain" --image nginx:alpine 2>&1)"
  status=$?
  assertEquals "update-backend recreate should succeed with stored JSON env docker opts" 0 "$status"
  assertStringContains "update-backend output should report backend update" "Backend '${domain}' updated." "$output"

  local opts_file="${CONFIG_DIR}/backend_docker_opts.csv"
  local stored_line stored_opts
  stored_line="$(grep "^backend:${domain}," "$opts_file" | head -n 1 || true)"
  if [ -z "$stored_line" ] || ! csv_parse_line "$stored_line" || [ "$CSV_FIELD_COUNT" -lt 2 ]; then
    fail "Expected valid docker opts CSV row for backend:${domain}"
    return
  fi
  stored_opts="${CSV_FIELDS[1]-}"

  assertEquals "stored docker opts should survive update-backend recreate" "$expected_opts" "$stored_opts"
  assertTrue "update-backend recreate should replay JSON env token without extra escaping" \
    "grep -Fq 'subcommand=run -d --name ${cname} --network dockistrate-net -e ELASTICSEARCH_HOSTS=[\"http://elasticsearch:9200\"] --label app=kibana nginx:alpine' '$docker_log_file'"
}
