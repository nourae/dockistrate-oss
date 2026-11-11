#!/usr/bin/env bash

function test_update_nginx_config_rejects_unowned_backend_without_state_changes() {
  local domain=identity-routing.test cname=backend-identity-routing.test
  local output status foreign_id snapshot_dir
  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  assertEquals 'managed backend seed succeeds' 0 $?
  SKIP_DOCKER_CHECKS=false run_dockistrate add-port "$domain" 19200 18180 tcp none >/dev/null
  assertEquals 'TCP routing seed succeeds' 0 $?
  snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_identity_routing.XXXXXX")"
  cp -R "$CONFIG_DIR" "$snapshot_dir/config"
  # A foreign container cannot be created through Dockistrate; this directly
  # invokes the mock to model a different actor on the Docker daemon.
  PATH="${MOCK_BIN_DIR}:$PATH" docker rm -f "$cname" >/dev/null
  foreign_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name "$cname" --network foreign-net nginx:alpine)"
  cp -R "$STATE_DIR/tmp/.docker_mock" "$snapshot_dir/docker"
  output="$(SKIP_DOCKER_CHECKS=false DOCKER_MOCK_INSPECT_NETWORK_MAP='foreign-net=10.66.0.9' \
    DOCKER_MOCK_LOG_FILE="$snapshot_dir/docker.log" run_dockistrate update-nginx-config 2>&1)"
  status=$?
  assertNotEquals 'config refresh rejects a stale owned ID and foreign name occupant' 0 "$status"
  assertStringContains 'failure identifies saved container absence' 'same-name replacement' "$output"
  assertTrue 'HTTP/TCP routing and persisted config remain byte-identical' "diff -r '$snapshot_dir/config' '$CONFIG_DIR' >/dev/null"
  assertTrue 'foreign backend and proxy runtime metadata remain identical' "diff -r '$snapshot_dir/docker' '$STATE_DIR/tmp/.docker_mock' >/dev/null"
  assertFalse 'refresh cannot attach a foreign network or mutate containers' "grep -Eq '^subcommand=(run|start|stop|restart|rm|rename|network (connect|disconnect|create|rm)) ' '$snapshot_dir/docker.log'"
  assertEquals 'foreign full ID remains present' "$foreign_id" "$(PATH="${MOCK_BIN_DIR}:$PATH" docker inspect -f '{{.Id}}' "$cname")"
  rm -rf "$snapshot_dir"
}

function test_update_backend_explicit_legacy_replacement_preserves_config() {
  local domain=identity-legacy.test cname=backend-identity-legacy.test original_id new_id output status original_mapping
  run_dockistrate add-backend "$domain" nginx:alpine 18180 http --docker-opts '--label app=legacy' >/dev/null
  assertEquals 'legacy state seed succeeds' 0 $?
  original_mapping="$(grep "^port,$domain," "$CONFIG_DIR/backend_ports.csv")"
  original_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name "$cname" --network dockistrate-net --label app=legacy nginx:alpine)"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$domain" --replace-unmanaged-container "$original_id" --image nginx:alpine 2>&1)"
  status=$?
  assertEquals 'explicit legacy replacement succeeds' 0 "$status"
  assertStringContains 'replacement reports backend update' "Backend '$domain' updated." "$output"
  new_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker inspect -f '{{.Id}}' "$cname")"
  assertNotEquals 'replacement creates a new immutable ID' "$original_id" "$new_id"
  assertTrue 'saved identity binds the new full ID to a valid token' "grep -Eq '^$domain,$new_id,[0-9a-f]{32}$' '$CONFIG_DIR/backend_identity.csv'"
  assertFileContains "$domain,--label app=legacy" "$CONFIG_DIR/backend_docker_opts.csv"
  assertEquals 'explicit recovery preserves the entire port mapping row' "$original_mapping" "$(grep "^port,$domain," "$CONFIG_DIR/backend_ports.csv")"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate restart-backend "$domain" 2>&1)"
  assertEquals 'recovered backend supports ordinary verified restart' 0 $?
  assertFalse 'legacy original is gone after successful commit' "PATH='$MOCK_BIN_DIR:$PATH' docker inspect -f '{{.Id}}' '$original_id' >/dev/null 2>&1"
}

function test_update_backend_explicit_legacy_replacement_rolls_back() {
  local domain=identity-legacy-rollback.test cname=backend-identity-legacy-rollback.test original_id original_upstream output status snapshot_dir
  run_dockistrate add-backend "$domain" nginx:alpine 18180 http --docker-opts '--label app=legacy' >/dev/null
  assertEquals 'legacy rollback state seed succeeds' 0 $?
  original_upstream="$(awk -F, -v target="$domain" '$1 == "backend" && $2 == target { print $3; exit }' "$CONFIG_DIR/backend_ports.csv")"
  original_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name "$cname" --network dockistrate-net nginx:alpine)"
  snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_identity_rollback.XXXXXX")"
  cp -R "$CONFIG_DIR" "$snapshot_dir/config"
  # This case keeps the old container's address. A different mock default would
  # correctly refresh restored routes, invalidating the byte-for-byte assertion.
  output="$(SKIP_DOCKER_CHECKS=false DOCKER_MOCK_INSPECT_NETWORK_IP="${original_upstream%:*}" \
    DOCKER_MOCK_EXEC_FAIL=true DOCKER_MOCK_LOG_FILE="$snapshot_dir/docker.log" run_dockistrate update-backend "$domain" \
    --replace-unmanaged-container "$original_id" --image nginx:alpine 2>&1)"
  status=$?
  assertNotEquals 'downstream render failure aborts legacy replacement' 0 "$status"
  assertStringContains 'legacy replacement reports rollback' 'failed. Rolled back.' "$output"
  assertTrue 'legacy config and missing identity are restored' "diff -r '$snapshot_dir/config' '$CONFIG_DIR' >/dev/null"
  assertEquals 'rollback restores the exact original container' "$original_id" "$(PATH="${MOCK_BIN_DIR}:$PATH" docker inspect -f '{{.Id}}' "$cname")"
  assertEquals 'rollback restores original running state' running "$(PATH="${MOCK_BIN_DIR}:$PATH" docker inspect -f '{{.State.Status}}' "$original_id")"
  assertFalse 'rollback never removes the legacy original' "grep -Eq '^subcommand=rm -f( -v)? $original_id$' '$snapshot_dir/docker.log'"
  rm -rf "$snapshot_dir"
}

function test_update_backend_explicit_legacy_replacement_rejects_unproven_targets() {
  local domain=identity-legacy-guard.test cname=backend-identity-legacy-guard.test original_id foreign_id output status target snapshot_dir
  run_dockistrate add-backend "$domain" nginx:alpine 18180 http >/dev/null
  original_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name "$cname" --network dockistrate-net nginx:alpine)"
  foreign_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name unrelated --network dockistrate-net nginx:alpine)"
  snapshot_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_identity_guards.XXXXXX")"
  cp -R "$CONFIG_DIR" "$snapshot_dir/config"
  cp -R "$STATE_DIR/tmp/.docker_mock" "$snapshot_dir/docker"
  for target in "${original_id:0:12}" "$(printf '%064d' 1)" "$foreign_id"; do
    output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$domain" --replace-unmanaged-container "$target" --image nginx:alpine 2>&1)"
    status=$?
    assertNotEquals 'short, absent, or wrongly named recovery target is rejected' 0 "$status"
  done
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$domain" --replace-unmanaged-container "$original_id" 2>&1)"
  assertNotEquals 'recovery requires explicit replacement image' 0 $?
  assertTrue 'invalid recovery leaves config unchanged' "diff -r '$snapshot_dir/config' '$CONFIG_DIR' >/dev/null"
  assertTrue 'invalid recovery leaves both containers unchanged' "diff -r '$snapshot_dir/docker' '$STATE_DIR/tmp/.docker_mock' >/dev/null"
  printf 'domain,container_id,ownership_token\n%s,invalid,bad\n' "$domain" >"$CONFIG_DIR/backend_identity.csv"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$domain" --replace-unmanaged-container "$original_id" --image nginx:alpine 2>&1)"
  assertNotEquals 'malformed existing identity cannot authorize recovery' 0 $?
  printf 'domain,container_id,ownership_token\n%s,%s,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$domain" "$original_id" >"$CONFIG_DIR/backend_identity.csv"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$domain" --replace-unmanaged-container "$original_id" --image nginx:alpine 2>&1)"
  assertNotEquals 'existing ownership record cannot be bypassed with recovery flag' 0 $?
  assertTrue 'invalid existing identity never changes containers' "diff -r '$snapshot_dir/docker' '$STATE_DIR/tmp/.docker_mock' >/dev/null"
  rm -rf "$snapshot_dir"
}

function _backend_identity_failure_diagnostics() {
  local stage="$1" status="$2" output="$3"
  local diagnostics_dir source
  printf '[tests] Legacy replacement failure: stage=%s status=%s\n' "$stage" "$status" >&2
  printf '[tests] Captured output:\n%s\n' "${output:-<empty>}" >&2
  # setUp and tearDown reset STATE_DIR. Keep private failure evidence outside it,
  # including when a caller's TMPDIR happens to point into the fixture state.
  (
    umask 077
    diagnostics_dir="$(mktemp -d /tmp/dockistrate_identity_failure.XXXXXX)" || {
      printf '[tests] Could not create a failure artifact directory.\n' >&2
      exit 0
    }
    if ! printf 'stage=%s\nstatus=%s\nstate_dir=%s\n' "$stage" "$status" "$STATE_DIR" >"$diagnostics_dir/result.txt"; then
      printf '[tests] Could not retain the failure result.\n' >&2
    fi
    if ! printf '%s\n' "$output" >"$diagnostics_dir/command-output.log"; then
      printf '[tests] Could not retain command output.\n' >&2
    fi
    for source in "$CONFIG_DIR" "$STATE_DIR/logs" "$STATE_DIR/tmp/.docker_mock"; do
      if [ -e "$source" ] || [ -L "$source" ]; then
        if ! cp -Rp "$source" "$diagnostics_dir/"; then
          printf '[tests] Could not fully retain fixture path: %s\n' "$source" >&2
        fi
      fi
    done
    {
      date -u
      ls -ld "$STATE_DIR" "$CONFIG_DIR" "$STATE_DIR/logs" "$STATE_DIR/tmp/.docker_mock"
      df -Pk "$STATE_DIR" "$diagnostics_dir"
    } >"$diagnostics_dir/filesystem.log" 2>&1 ||
      printf '[tests] Could not fully retain filesystem diagnostics.\n' >&2
    printf '[tests] Failure artifacts: %s\n' "$diagnostics_dir" >&2
  )
  # Reporting failures must not replace the command status used by assertions.
  return 0
}

function test_update_backend_explicit_legacy_replacement_preserves_other_legacy_rows() {
  local first=identity-first.test second=identity-second.test first_id second_id untouched_row actual_row output status
  output="$(run_dockistrate add-backend "$first" nginx:alpine 18180 http 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics seed-first "$status" "$output"
  output="$(run_dockistrate add-backend "$second" nginx:alpine 18181 http 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics seed-second "$status" "$output"
  first_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name "backend-$first" --network dockistrate-net nginx:alpine)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics seed-first-container "$status" "$first_id"
  second_id="$(PATH="${MOCK_BIN_DIR}:$PATH" docker run -d --name "backend-$second" --network foreign-net nginx:alpine)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics seed-second-container "$status" "$second_id"
  untouched_row="$(grep "^backend,$second," "$CONFIG_DIR/backend_ports.csv")"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics read-legacy-row "$status" "$untouched_row"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$first" --replace-unmanaged-container "$first_id" --image nginx:alpine 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics migrate-first "$status" "$output"
  assertEquals 'first explicit migration can preserve other legacy state' 0 "$status"
  actual_row="$(grep "^backend,$second," "$CONFIG_DIR/backend_ports.csv")"
  status=$?
  if [ "$status" -ne 0 ] || [ "$untouched_row" != "$actual_row" ]; then
    _backend_identity_failure_diagnostics row-after-first "$status" "expected: $untouched_row
actual: $actual_row"
  fi
  assertEquals 'other legacy row is byte-identical and not refreshed' "$untouched_row" "$actual_row"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-nginx-config 2>&1)"
  status=$?
  [ "$status" -ne 0 ] || _backend_identity_failure_diagnostics reject-remaining-legacy "$status" "$output"
  assertNotEquals 'ordinary refresh still refuses the remaining legacy backend' 0 "$status"
  actual_row="$(grep "^backend,$second," "$CONFIG_DIR/backend_ports.csv")"
  status=$?
  if [ "$status" -ne 0 ] || [ "$untouched_row" != "$actual_row" ]; then
    _backend_identity_failure_diagnostics row-after-rejection "$status" "expected: $untouched_row
actual: $actual_row"
  fi
  assertEquals 'ordinary rejection preserves legacy state' "$untouched_row" "$actual_row"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-backend "$second" --replace-unmanaged-container "$second_id" --image nginx:alpine 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics migrate-second "$status" "$output"
  assertEquals 'second explicit migration succeeds' 0 "$status"
  output="$(SKIP_DOCKER_CHECKS=false run_dockistrate update-nginx-config 2>&1)"
  status=$?
  [ "$status" -eq 0 ] || _backend_identity_failure_diagnostics refresh-after-migration "$status" "$output"
  assertEquals 'ordinary refresh succeeds after all legacy backends are verified' 0 "$status"
}
