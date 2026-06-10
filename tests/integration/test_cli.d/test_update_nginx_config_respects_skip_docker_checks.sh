#!/usr/bin/env bash

test_update_nginx_config_respects_skip_docker_checks() {
  local fake_bin status output
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate.XXXXXX")"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    cat <<'EOF'
echo "docker should not be called when SKIP_DOCKER_CHECKS=true" >&2
exit 99
EOF
  } >"${fake_bin}/docker"
  chmod +x "${fake_bin}/docker"

  output="$(cd "$ROOT_DIR" && PATH="${fake_bin}:$PATH" SKIP_DOCKER_CHECKS=true ./dockistrate.sh update-nginx-config 2>&1)"
  status=$?

  rm -rf "$fake_bin"

  assertEquals "update-nginx-config should succeed without docker checks" 0 $status
  assertStringContains "skip docker update output" "Nginx configuration updated." "$output"
}
