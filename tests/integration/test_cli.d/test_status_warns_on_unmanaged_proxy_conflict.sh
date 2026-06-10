#!/usr/bin/env bash

test_status_warns_on_unmanaged_proxy_conflict() {
  local output
  output="$(DOCKER_MOCK_PS_NAMES="nginx-proxy" DOCKER_MOCK_PROXY_MANAGED=false DOCKER_MOCK_INSPECT_STATUS=running run_dockistrate status)"
  local status=$?

  assertEquals "status should succeed with an unmanaged proxy-name collision" 0 "$status"
  assertStringContains "status should warn about unmanaged nginx-proxy" "not Dockistrate-managed" "$output"
  assertTrue "status should not report the unmanaged container as the managed proxy" \
    "! printf '%s' \"$output\" | grep -Fq 'nginx-proxy status:'"
}

test_status_warns_on_foreign_checkout_proxy_conflict() {
  local output
  output="$(DOCKER_MOCK_PS_NAMES="nginx-proxy" DOCKER_MOCK_PROXY_STATE_DIR="/tmp/foreign-dockistrate-state" DOCKER_MOCK_INSPECT_STATUS=running run_dockistrate status)"
  local status=$?

  assertEquals "status should succeed with a foreign-checkout proxy collision" 0 "$status"
  assertStringContains "status should warn about a foreign-checkout nginx-proxy" "not Dockistrate-managed by this checkout" "$output"
  assertTrue "status should not report the foreign-checkout proxy as managed" \
    "! printf '%s' \"$output\" | grep -Fq 'nginx-proxy status:'"
}

test_status_treats_legacy_unlabeled_proxy_as_managed_when_labels_are_missing() {
  local output
  local legacy_mounts
  legacy_mounts="$(cat <<EOF
${CONFIG_DIR}/nginx_conf|/etc/nginx/dockistrate|false
${CERTS_DIR}|/etc/letsencrypt|false
${ROOT_DIR}/state/acme-webroot|/var/www/certbot|false
EOF
)"

  output="$(DOCKER_MOCK_PS_NAMES="nginx-proxy" \
    DOCKER_MOCK_PROXY_MANAGED=false \
    DOCKER_MOCK_MISSING_LABEL_OUTPUT="<no value>" \
    DOCKER_MOCK_INSPECT_MOUNTS="$legacy_mounts" \
    DOCKER_MOCK_INSPECT_STATUS=running \
    run_dockistrate status)"
  local status=$?

  assertEquals "status should succeed for a legacy unmanaged-label proxy with Dockistrate mounts" 0 "$status"
  assertTrue "status should report the legacy proxy as the managed proxy" \
    "printf '%s' \"$output\" | grep -Fq 'nginx-proxy status: running'"
  assertTrue "status should not warn about a conflict for a legacy managed proxy" \
    "! printf '%s' \"$output\" | grep -Fq 'not Dockistrate-managed'"
}
