#!/usr/bin/env bash

function _write_certbot_darwin_stubs() {
  local fake_bin="${1:-}"

  mkdir -p "$fake_bin"
  if [ -n "${CONFIG_DIR:-}" ]; then
    mkdir -p "$CONFIG_DIR"
    # Integration setup already seeds the current named-field records.
    printf '5\n' >"$CONFIG_DIR/state_schema_version"
  fi
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "%s\n" "${UNAME_MOCK_VALUE:-Darwin}"'
  } >"${fake_bin}/uname"
  chmod +x "${fake_bin}/uname"

  # Simulate sudo eligibility through the UID only. Filesystem operations such
  # as rollback staging must still see the process's real effective group.
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  -u) printf "%s\n" "${ID_MOCK_UID:-0}" ;;'
    printf '%s\n' '  *) /usr/bin/id "$@" ;;'
    printf '%s\n' 'esac'
  } >"${fake_bin}/id"
  chmod +x "${fake_bin}/id"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'target=""'
    printf '%s\n' 'for arg in "$@"; do'
    printf '%s\n' '  target="$arg"'
    printf '%s\n' 'done'
    printf '%s\n' 'if [ "${STAT_MOCK_GNU_F_NOISE:-false}" = "true" ] && [ "${1:-} ${2:-}" = "-f %u %g %Lp" ]; then'
    printf '%s\n' '  printf "  File: %s\n" "$target"'
    printf '%s\n' '  printf "    ID: mocked Namelen: 255 Type: apfs\n"'
    printf '%s\n' '  exit 1'
    printf '%s\n' 'fi'
    printf '%s\n' 'case "${1:-} ${2:-}" in'
    printf '%s\n' '  "-f %u %g %Lp" | "-c %u %g %a")'
    printf '%s\n' '    if [ -n "${STAT_MOCK_NESTED_PATH:-}" ] && [ "$target" = "$STAT_MOCK_NESTED_PATH" ]; then'
    printf '%s\n' '      printf "%s %s %s\n" "${STAT_MOCK_NESTED_UID:-0}" "${STAT_MOCK_NESTED_GID:-0}" "${STAT_MOCK_NESTED_MODE:-750}"'
    printf '%s\n' '    else'
    printf '%s\n' '      printf "%s %s %s\n" "${STAT_MOCK_UID:-501}" "${STAT_MOCK_GID:-20}" "${STAT_MOCK_MODE:-750}"'
    printf '%s\n' '    fi'
    printf '%s\n' '    exit 0'
    printf '%s\n' '    ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'exec /usr/bin/stat "$@"'
  } >"${fake_bin}/stat"
  chmod +x "${fake_bin}/stat"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if [ -n "${CHOWN_MOCK_LOG_FILE:-}" ]; then'
    printf '%s\n' '  {'
    printf '%s\n' '    printf "chown"'
    printf '%s\n' '    for arg in "$@"; do'
    printf '%s\n' '      printf " %s" "$arg"'
    printf '%s\n' '    done'
    printf '%s\n' '    printf "\n"'
    printf '%s\n' '  } >>"$CHOWN_MOCK_LOG_FILE"'
    # Keep argv boundaries separately: the human-readable trace is ambiguous
    # when a path contains spaces or a newline.
    printf '%s\n' '  printf "%s\0" "$#" "$@" >>"${CHOWN_MOCK_LOG_FILE}.chown-argv"'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } >"${fake_bin}/chown"
  chmod +x "${fake_bin}/chown"
}

function _run_dockistrate_with_darwin_certbot_env() {
  local fake_bin="${1:-}"
  local docker_log_file="${2:-}"
  local repair_uid=501 repair_gid=20
  shift 2
  # Explicit repair now uses descriptor-bound ownership verification. Exercise
  # real ownership on the invoking test account, including non-root macOS;
  # fake successful chown output cannot stand in for a real filesystem change.
  if [ "${1:-}" = fix-permissions ] && [ "${2:-}" = --certbot-darwin-user ]; then
    repair_uid="$(/usr/bin/id -u)"
    repair_gid="$(/usr/bin/id -g)"
  fi

  (
    cd "$ROOT_DIR" &&
      PATH="${fake_bin}:${MOCK_BIN_DIR}:$PATH" \
        SKIP_DOCKER_CHECKS="${SKIP_DOCKER_CHECKS:-true}" \
        DOCKER_MOCK_LOG_FILE="$docker_log_file" \
        CHOWN_MOCK_LOG_FILE="$docker_log_file" \
        UNAME_MOCK_VALUE="${UNAME_MOCK_VALUE:-Darwin}" \
        ID_MOCK_UID="${ID_MOCK_UID:-0}" \
        STAT_MOCK_UID="${STAT_MOCK_UID:-$repair_uid}" \
        STAT_MOCK_GID="${STAT_MOCK_GID:-$repair_gid}" \
        STAT_MOCK_MODE="${STAT_MOCK_MODE:-750}" \
        STAT_MOCK_NESTED_PATH="${STAT_MOCK_NESTED_PATH:-}" \
        STAT_MOCK_NESTED_UID="${STAT_MOCK_NESTED_UID:-0}" \
        STAT_MOCK_NESTED_GID="${STAT_MOCK_NESTED_GID:-0}" \
        STAT_MOCK_NESTED_MODE="${STAT_MOCK_NESTED_MODE:-750}" \
        STAT_MOCK_GNU_F_NOISE="${STAT_MOCK_GNU_F_NOISE:-false}" \
        SUDO_UID="$repair_uid" \
        SUDO_GID="$repair_gid" \
        ./dockistrate.sh "$@" 2>&1
  )
}

function _assert_certbot_darwin_standalone_args() {
  local docker_log_file="${1:-}"
  local context="${2:-certbot}"

  assertTrue "${context} should pass sudo user mapping to certbot" \
    "grep -Eq -- 'subcommand=run .* --user 501:20( |$)' '${docker_log_file}'"
  assertTrue "${context} should not fall back to root mapping under sudo" \
    "! grep -Fq -- '--user 0:0' '${docker_log_file}'"
  assertTrue "${context} standalone certbot should add bind-service capability" \
    "grep -Eq -- 'subcommand=run .* --cap-add=NET_BIND_SERVICE( |$)' '${docker_log_file}'"
}

function _assert_certbot_no_mount_ownership_mutation() {
  local docker_log_file="${1:-}"
  local context="${2:-certbot}"
  local status=0

  _certbot_only_expected_log_ownership_repairs "$docker_log_file" || status=$?
  assertTrue "${context} should not change Certbot mount ownership" "$status"
}

function _certbot_only_expected_log_ownership_repairs() {
  local docker_log_file="${1:-}" count="" owner="" directory="" file=""
  local user="" group="" records=0
  local argv_file="${docker_log_file}.chown-argv"

  # No ownership call is valid without its complete structured record.
  if [ ! -s "$argv_file" ]; then
    ! grep -Eq -- '^chown( |$)' "$docker_log_file"
    return $?
  fi

  # The UID stub simulates sudo eligibility; the logging helper uses the real
  # EUID and invoking user. Only its exact directory + log-file repair is exempt.
  if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    user="$SUDO_USER"
  else
    user="$(/usr/bin/id -un)" || return 1
  fi
  group="$(/usr/bin/id -gn "$user" 2>/dev/null)" || group="$user"

  while IFS= read -r -d '' count; do
    [ "$count" = 3 ] || return 1
    IFS= read -r -d '' owner || return 1
    IFS= read -r -d '' directory || return 1
    IFS= read -r -d '' file || return 1
    [ "$owner" = "${user}:${group}" ] || return 1
    [ "$directory" = "$LOG_DIR" ] || return 1
    case "$file" in
    "$LOG_DIR/audit.log" | "$LOG_DIR/docker_manager.log") ;;
    *) return 1 ;;
    esac
    records=$((records + 1))
  done <"$argv_file"
  [ -z "$count" ] && [ "$records" -gt 0 ]
}

function _assert_certbot_no_user_mapping_args() {
  local docker_log_file="${1:-}"
  local context="${2:-certbot}"

  assertTrue "${context} should not pass Darwin user mapping" \
    "! grep -Eq -- 'subcommand=run .* --user ' '${docker_log_file}'"
  assertTrue "${context} should not add Darwin standalone capability" \
    "! grep -Eq -- 'subcommand=run .* --cap-add=NET_BIND_SERVICE( |$)' '${docker_log_file}'"
}

function _assert_certbot_darwin_mapping_failure_aborts() {
  local output="${1:-}" docker_log_file="${2:-}" context="${3:-certbot}"

  assertStringContains "${context} fail-closed error" "Refusing to run Darwin Certbot without host-user mapping" "$output"
  assertTrue "${context} should fail before certbot docker run" \
    "! grep -Eq -- 'subcommand=run .* certbot/certbot' '${docker_log_file}'"
  assertTrue "${context} should fail before pulling the certbot image" \
    "! grep -Eq -- 'subcommand=pull certbot/certbot' '${docker_log_file}'"
  assertTrue "${context} should not pass user mapping after mapping failure" \
    "! grep -Eq -- 'subcommand=run .* --user ' '${docker_log_file}'"
  assertTrue "${context} should not add bind-service capability after mapping failure" \
    "! grep -Eq -- 'subcommand=run .* --cap-add=NET_BIND_SERVICE( |$)' '${docker_log_file}'"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "$context"
}

function _certbot_test_mode() {
  local target="${1:-}" mode=""

  if mode="$(stat -c '%a' "$target" 2>/dev/null)"; then
    printf '%s' "$mode"
    return 0
  fi
  stat -f '%Lp' "$target"
}

function test_add_cert_letsencrypt_darwin_uses_sudo_user_mapping() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(_run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert darwin-standalone.example 443 letsencrypt)"
  status=$?

  assertEquals "add-cert should succeed on Darwin path" 0 $status
  assertStringContains "standalone mode indicator" "using standalone mode" "$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  _assert_certbot_darwin_standalone_args "$docker_log_file" "add-cert"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "add-cert"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_ignores_failed_gnu_stat_stdout() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-gnu-stat.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(STAT_MOCK_GNU_F_NOISE=true \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert darwin-gnu-stat.example 443 letsencrypt)"
  status=$?

  assertEquals "add-cert should ignore stdout from a failed stat dialect" 0 "$status"
  assertStringContains "GNU stat fallback standalone mode" "using standalone mode" \
    "$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  _assert_certbot_darwin_standalone_args "$docker_log_file" "GNU stat fallback"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "GNU stat fallback"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_non_darwin_standalone_continues_without_user_mapping() {
  local fake_bin docker_log_file output status cert_dir
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-linux-certbot.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(UNAME_MOCK_VALUE=Linux _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert linux-standalone.example 443 letsencrypt)"
  status=$?

  assertEquals "add-cert should preserve non-Darwin fallback behavior" 0 $status
  assertStringContains "non-Darwin standalone mode indicator" "using standalone mode" "$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  assertStringContains "non-Darwin letsencrypt placement message" "Let’s Encrypt cert placed" "$output"
  cert_dir="${STATE_DIR}/domains/linux-standalone.example/certs/letsencrypt-443"
  assertTrue "non-Darwin standalone cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "non-Darwin standalone fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "non-Darwin standalone privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"
  _assert_certbot_no_user_mapping_args "$docker_log_file" "non-Darwin standalone"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "non-Darwin standalone"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_non_darwin_webroot_continues_without_user_mapping() {
  local fake_bin docker_log_file output status cert_dir
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-linux-webroot-certbot.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  SKIP_DOCKER_CHECKS=false run_dockistrate add-backend challenge.example nginx:alpine 8080 http >/dev/null
  assertEquals "seed HTTP listener for non-Darwin webroot test" 0 $?
  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for non-Darwin webroot test" 0 $?

  output="$(UNAME_MOCK_VALUE=Linux DOCKER_MOCK_PORT_BINDINGS='80/tcp -> 0.0.0.0:80' _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert linux-webroot.example 443 letsencrypt)"
  status=$?

  assertEquals "add-cert webroot should preserve non-Darwin fallback behavior" 0 $status
  assertStringContains "non-Darwin webroot mode indicator" "Using webroot mode" "$output"
  assertStringContains "non-Darwin webroot letsencrypt placement message" "Let’s Encrypt cert placed" "$output"
  cert_dir="${STATE_DIR}/domains/linux-webroot.example/certs/letsencrypt-443"
  assertTrue "non-Darwin webroot cert directory should exist" "[ -d '${cert_dir}' ]"
  assertTrue "non-Darwin webroot fullchain should exist" "[ -f '${cert_dir}/fullchain.pem' ]"
  assertTrue "non-Darwin webroot privkey should exist" "[ -f '${cert_dir}/privkey.pem' ]"
  _assert_certbot_no_user_mapping_args "$docker_log_file" "non-Darwin webroot"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "non-Darwin webroot"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_fails_when_mounts_are_root_owned() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-perm.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(SKIP_DOCKER_CHECKS=false STAT_MOCK_UID=0 STAT_MOCK_GID=0 STAT_MOCK_MODE=750 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert darwin-root-owned-fail.example 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when Darwin mounts are root-owned" "[ $status -ne 0 ]"
  assertStringContains "add-cert Darwin mapping failure should roll back transaction" "command_add-cert failed. Rolled back." "$output"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "root-owned mount"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_fails_when_directory_lacks_execute() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-noexec.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(STAT_MOCK_MODE=620 _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert darwin-noexec-fail.example 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when mapped user has write without directory execute" "[ $status -ne 0 ]"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "write-without-execute mount"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_respects_owner_permission_precedence() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-owner.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(STAT_MOCK_UID=501 STAT_MOCK_GID=20 STAT_MOCK_MODE=070 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert darwin-owner-precedence.example 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when owner class lacks directory access" "[ $status -ne 0 ]"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "owner precedence mount"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_respects_group_permission_precedence() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-group.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(STAT_MOCK_UID=999 STAT_MOCK_GID=20 STAT_MOCK_MODE=007 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert darwin-group-precedence.example 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when group class lacks directory access" "[ $status -ne 0 ]"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "group precedence mount"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_fails_when_nested_archive_file_unwritable() {
  local fake_bin docker_log_file output status domain nested_file
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-nested-add.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  domain="darwin-nested-add.example"
  nested_file="${STATE_DIR}/shared/acme/archive/${domain}/privkey1.pem"
  _write_certbot_darwin_stubs "$fake_bin"

  mkdir -p "${nested_file%/*}"
  printf 'old-private-key\n' >"$nested_file"

  output="$(STAT_MOCK_NESTED_PATH="$nested_file" STAT_MOCK_NESTED_UID=501 STAT_MOCK_NESTED_GID=20 STAT_MOCK_NESTED_MODE=400 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert "$domain" 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when nested LE archive file is not writable by mapped user" "[ $status -ne 0 ]"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "nested archive"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_follows_symlinked_mount_root_before_user_mapping() {
  local fake_bin docker_log_file output status domain real_le_root le_symlink nested_file
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-symlink-add.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  domain="darwin-symlink-add.example"
  real_le_root="${TMP_DIR}/darwin-certbot-real-letsencrypt"
  le_symlink="${STATE_DIR}/shared/acme"
  nested_file="${le_symlink}/archive/${domain}/privkey1.pem"
  _write_certbot_darwin_stubs "$fake_bin"

  rm -rf "$le_symlink" "$real_le_root"
  mkdir -p "${le_symlink%/*}" "${real_le_root}/archive/${domain}"
  ln -s "$real_le_root" "$le_symlink"
  printf 'old-private-key\n' >"${fake_bin}/private-key-before"
  cp "${fake_bin}/private-key-before" "${real_le_root}/archive/${domain}/privkey1.pem"
  : >"$docker_log_file"

  output="$(STAT_MOCK_NESTED_PATH="$nested_file" STAT_MOCK_NESTED_UID=501 STAT_MOCK_NESTED_GID=20 STAT_MOCK_NESTED_MODE=400 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert "$domain" 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when symlinked LE mount root contains an unwritable nested file" "[ $status -ne 0 ]"
  case "$output" in
  *"Refusing to run Darwin Certbot without host-user mapping"* | *"Refusing to use symlinked runtime path component"* | \
    *"Transaction symlink must resolve within the selected snapshot targets"*) ;;
  *) fail "symlinked mount-root fail-closed error did not report a path/user-mapping guard: $output" ;;
  esac
  assertEquals "symlinked mount-root should retain its original target" "$real_le_root" "$(readlink "$le_symlink")"
  assertTrue "symlinked mount-root private key should remain unchanged" \
    "cmp -s '${fake_bin}/private-key-before' '${real_le_root}/archive/${domain}/privkey1.pem'"
  assertTrue "symlinked mount-root should fail before certbot docker run" \
    "! grep -Eq -- 'subcommand=run .* certbot/certbot' '${docker_log_file}'"
  assertTrue "symlinked mount-root should fail before pulling the certbot image" \
    "! grep -Eq -- 'subcommand=pull certbot/certbot' '${docker_log_file}'"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "symlinked mount-root"

  rm -rf "$fake_bin"
}

function test_renew_certs_letsencrypt_darwin_uses_sudo_user_mapping() {
  local fake_bin docker_log_file domain output status source_dir le_dir ports_file rewritten_file line
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-renew.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  domain="darwin-renew.example"
  _write_certbot_darwin_stubs "$fake_bin"

  run_dockistrate add-backend "$domain" nginx:alpine 8000 http >/dev/null
  assertEquals "seed backend for renew-certs Darwin test" 0 $?

  run_dockistrate add-port "$domain" 9443 8000 https none no >/dev/null
  assertEquals "seed HTTPS mapping for renew-certs Darwin test" 0 $?

  integration_seed_letsencrypt_fixture "$domain" 9443 || return


  : >"$docker_log_file"
  output="$(CERT_RENEWAL_WINDOW_DAYS=10000 _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" renew-certs)"
  status=$?

  assertEquals "renew-certs should succeed on Darwin path" 0 $status
  assertStringContains "renewal mode indicator" "using standalone mode" "$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  _assert_certbot_darwin_standalone_args "$docker_log_file" "renew-certs"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "renew-certs"

  rm -rf "$fake_bin"
}

function test_renew_certs_letsencrypt_darwin_fails_when_nested_archive_file_unwritable() {
  local fake_bin docker_log_file domain output status source_dir le_dir archive_file ports_file rewritten_file line
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-renew-nested.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  domain="darwin-renew-nested.example"
  _write_certbot_darwin_stubs "$fake_bin"

  run_dockistrate add-backend "$domain" nginx:alpine 8000 http >/dev/null
  assertEquals "seed backend for nested renew-certs Darwin test" 0 $?

  run_dockistrate add-port "$domain" 9443 8000 https none no >/dev/null
  assertEquals "seed HTTPS mapping for nested renew-certs Darwin test" 0 $?

  integration_seed_letsencrypt_fixture "$domain" 9443 || return
  archive_file="${STATE_DIR}/shared/acme/archive/${domain}/privkey1.pem"
  mkdir -p "${archive_file%/*}"
  printf 'old-private-key\n' >"$archive_file"


  : >"$docker_log_file"
  output="$(CERT_RENEWAL_WINDOW_DAYS=10000 STAT_MOCK_NESTED_PATH="$archive_file" STAT_MOCK_NESTED_UID=501 STAT_MOCK_NESTED_GID=20 STAT_MOCK_NESTED_MODE=400 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" renew-certs)"
  status=$?

  assertTrue "renew-certs should fail closed when nested LE archive file is not writable by mapped user" "[ $status -ne 0 ]"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "nested renew archive"

  rm -rf "$fake_bin"
}

function test_add_cert_letsencrypt_darwin_does_not_reown_existing_le_private_keys() {
  local fake_bin docker_log_file output status target_domain existing_key
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-existing-key.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  target_domain="darwin-existing-key-new.example"
  existing_key="${STATE_DIR}/shared/acme/archive/existing.example/privkey1.pem"
  _write_certbot_darwin_stubs "$fake_bin"

  mkdir -p "${existing_key%/*}"
  printf 'existing-private-key\n' >"$existing_key"

  output="$(STAT_MOCK_NESTED_PATH="$existing_key" STAT_MOCK_NESTED_UID=0 STAT_MOCK_NESTED_GID=0 STAT_MOCK_NESTED_MODE=600 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert "$target_domain" 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when existing LE private keys are not writable by mapped user" "[ $status -ne 0 ]"
  _assert_certbot_darwin_mapping_failure_aborts "$output" "$docker_log_file" "existing LE private key"

  rm -rf "$fake_bin"
}

function test_fix_permissions_certbot_darwin_user_prepares_mounts_explicitly() {
  local fake_bin docker_log_file output status le_root acme_root private_key public_cert acme_token
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-prep.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  le_root="${STATE_DIR}/shared/acme"
  acme_root="${STATE_DIR}/acme-webroot"
  private_key="${le_root}/archive/prepared.example/privkey1.pem"
  public_cert="${le_root}/live/prepared.example/fullchain.pem"
  acme_token="${acme_root}/.well-known/acme-challenge/token"
  _write_certbot_darwin_stubs "$fake_bin"

  mkdir -p "${private_key%/*}" "${public_cert%/*}" "${acme_token%/*}"
  printf 'private-key\n' >"$private_key"
  printf 'public-cert\n' >"$public_cert"
  printf 'challenge\n' >"$acme_token"
  chmod 666 "$private_key" "$public_cert" "$acme_token"

  output="$(_run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertEquals "explicit Darwin Certbot prep should succeed" 0 $status
  assertStringContains "explicit prep completion" "Prepared Darwin Certbot mounts for $(/usr/bin/id -u):$(/usr/bin/id -g)" "$output"
  local ownership_path ownership
  for ownership_path in "$le_root" "$private_key" "$public_cert" "$acme_root" "$acme_token"; do
    ownership="$(/usr/bin/stat -c '%u:%g' "$ownership_path" 2>/dev/null || /usr/bin/stat -f '%u:%g' "$ownership_path")"
    assertEquals "explicit repair verifies actual ownership of $ownership_path" "$(/usr/bin/id -u):$(/usr/bin/id -g)" "$ownership"
  done
  assertEquals "private keys stay restricted" "600" "$(_certbot_test_mode "$private_key")"
  assertEquals "public certs stay owner-writable but restricted" "640" "$(_certbot_test_mode "$public_cert")"
  assertEquals "ACME files stay owner-writable but restricted" "640" "$(_certbot_test_mode "$acme_token")"
  assertEquals "LE directories stay owner-writable but restricted" "750" "$(_certbot_test_mode "$le_root")"
  assertEquals "ACME directories stay owner-writable but restricted" "750" "$(_certbot_test_mode "$acme_root")"

  rm -rf "$fake_bin"
}

function test_fix_permissions_certbot_darwin_user_rejects_symlinked_letsencrypt_root() {
  local fake_bin docker_log_file output status le_root real_le_root
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-prep-symlink-le.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  le_root="${STATE_DIR}/shared/acme"
  real_le_root="${TMP_DIR}/darwin-certbot-prep-real-letsencrypt"
  _write_certbot_darwin_stubs "$fake_bin"

  rm -rf "$le_root" "$real_le_root"
  mkdir -p "${le_root%/*}" "$real_le_root"
  ln -s "$real_le_root" "$le_root"

  output="$(_run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertTrue "explicit Darwin Certbot prep should reject symlinked LE root" "[ $status -ne 0 ]"
  assertStringContains "symlinked LE rejection" "Refusing to prepare symlinked Darwin Certbot Let's Encrypt mount root" "$output"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "symlinked LE explicit prep"

  rm -rf "$fake_bin" "$le_root" "$real_le_root"
}

function test_fix_permissions_certbot_darwin_user_rejects_symlinked_acme_root() {
  local fake_bin docker_log_file output status acme_root real_acme_root
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-prep-symlink-acme.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  acme_root="${STATE_DIR}/acme-webroot"
  real_acme_root="${TMP_DIR}/darwin-certbot-prep-real-acme"
  _write_certbot_darwin_stubs "$fake_bin"

  rm -rf "$acme_root" "$real_acme_root"
  mkdir -p "$real_acme_root"
  ln -s "$real_acme_root" "$acme_root"

  output="$(_run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertTrue "explicit Darwin Certbot prep should reject symlinked ACME root" "[ $status -ne 0 ]"
  case "$output" in
  *"Refusing to prepare symlinked Darwin Certbot ACME webroot"* | *"Refusing to use symlinked runtime path component"*) ;;
  *) fail "symlinked ACME rejection did not report a fail-closed path guard: $output" ;;
  esac
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "symlinked ACME explicit prep"

  rm -rf "$fake_bin" "$acme_root" "$real_acme_root"
}

function test_fix_permissions_certbot_darwin_user_does_not_follow_nested_symlinks() {
  local fake_bin docker_log_file output status le_root acme_root private_key outside_dir outside_file nested_link
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-prep-nested-symlink.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  le_root="${STATE_DIR}/shared/acme"
  acme_root="${STATE_DIR}/acme-webroot"
  private_key="${le_root}/archive/prepared.example/privkey1.pem"
  outside_dir="${TMP_DIR}/darwin-certbot-prep-outside"
  outside_file="${outside_dir}/outside-key.pem"
  nested_link="${le_root}/archive/prepared.example/outside-key.pem"
  _write_certbot_darwin_stubs "$fake_bin"

  rm -rf "$le_root" "$acme_root" "$outside_dir"
  mkdir -p "${private_key%/*}" "$acme_root" "$outside_dir"
  printf 'private-key\n' >"$private_key"
  printf 'outside-key\n' >"$outside_file"
  chmod 666 "$private_key" "$outside_file"
  ln -s "$outside_file" "$nested_link"

  output="$(_run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertEquals "explicit Darwin Certbot prep should succeed with nested symlinks ignored" 0 $status
  assertStringContains "explicit prep completion with nested symlink" "Prepared Darwin Certbot mounts for $(/usr/bin/id -u):$(/usr/bin/id -g)" "$output"
  assertTrue "explicit prep should not chown nested symlink target" \
    "! grep -Fq -- '${outside_file}' '${docker_log_file}'"
  assertEquals "nested symlink target mode should stay unchanged" "666" "$(_certbot_test_mode "$outside_file")"
  assertEquals "real private key should still be restricted" "600" "$(_certbot_test_mode "$private_key")"

  rm -rf "$fake_bin" "$le_root" "$acme_root" "$outside_dir"
}

function test_fix_permissions_certbot_darwin_user_rejects_symlinked_state_root_before_creation() {
  local fake_bin docker_log_file output status outside_root
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-state-link.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  outside_root="${fake_bin}/outside-state"
  _write_certbot_darwin_stubs "$fake_bin"
  : >"$docker_log_file"
  mkdir -p "$outside_root"
  printf 'outside sentinel\n' >"${outside_root}/sentinel.key"
  chmod 777 "$outside_root"
  chmod 666 "${outside_root}/sentinel.key"
  rm -rf "$STATE_DIR"
  ln -s "$outside_root" "$STATE_DIR"

  output="$(_run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertTrue "Darwin repair rejects symlinked state root before creating missing leaves" "[ $status -ne 0 ]"
  assertStringContains "state root prefix guard" "symlinked runtime path component" "$output"
  assertFalse "rejected state alias must not create certs" "[ -e '${outside_root}/certs' ]"
  assertFalse "rejected state alias must not create ACME webroot" "[ -e '${outside_root}/acme-webroot' ]"
  assertEquals "outside directory mode remains unchanged" 777 "$(_certbot_test_mode "$outside_root")"
  assertEquals "outside key mode remains unchanged" 666 "$(_certbot_test_mode "${outside_root}/sentinel.key")"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "state-root alias"

  rm -f "$STATE_DIR"
  rm -rf "$fake_bin"
}

function test_fix_permissions_certbot_darwin_user_rejects_symlinked_state_ancestor_before_creation() {
  local fake_bin docker_log_file output status outside_root checkout alias_root
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-state-parent.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  outside_root="${fake_bin}/outside-parent"
  checkout="${outside_root}/checkout"
  alias_root="${fake_bin}/parent-alias"
  _write_certbot_darwin_stubs "$fake_bin"
  : >"$docker_log_file"
  mkdir -p "$checkout/state"
  cp "$ROOT_DIR/dockistrate.sh" "$ROOT_DIR/VERSION" "$checkout/"
  cp -R "$ROOT_DIR/lib" "$ROOT_DIR/config" "$checkout/"
  printf 'outside sentinel\n' >"$checkout/state/sentinel.key"
  chmod 777 "$checkout/state"
  chmod 666 "$checkout/state/sentinel.key"
  ln -s "$outside_root" "$alias_root"

  output="$(PATH="${fake_bin}:${MOCK_BIN_DIR}:$PATH" SKIP_DOCKER_CHECKS=true \
    DOCKER_MOCK_LOG_FILE="$docker_log_file" CHOWN_MOCK_LOG_FILE="$docker_log_file" \
    SUDO_UID=501 SUDO_GID=20 "$BASH" "$alias_root/checkout/dockistrate.sh" \
    fix-permissions --certbot-darwin-user 2>&1)"
  status=$?

  assertTrue "Darwin repair rejects symlinked state ancestor before creating missing leaves" "[ $status -ne 0 ]"
  assertStringContains "state ancestor prefix guard" "symlinked runtime path component" "$output"
  assertFalse "rejected parent alias must not create certs" "[ -e '${checkout}/state/certs' ]"
  assertFalse "rejected parent alias must not create ACME webroot" "[ -e '${checkout}/state/acme-webroot' ]"
  assertEquals "outside state directory mode remains unchanged" 777 "$(_certbot_test_mode "$checkout/state")"
  assertEquals "outside key mode remains unchanged" 666 "$(_certbot_test_mode "$checkout/state/sentinel.key")"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "state ancestor alias"

  rm -rf "$fake_bin"
}

function test_fix_permissions_certbot_darwin_user_rejects_non_darwin_without_chown() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-prep-linux.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(UNAME_MOCK_VALUE=Linux _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertTrue "explicit Darwin Certbot prep should fail off Darwin" "[ $status -ne 0 ]"
  assertStringContains "non-Darwin rejection" "only supported on macOS/Darwin" "$output"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "non-Darwin explicit prep"

  rm -rf "$fake_bin"
}

function test_fix_permissions_certbot_darwin_user_direct_source_rejects_mount_ancestor_alias() {
  local fake_bin docker_log_file output status outside_root alias_root
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-direct-source.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  outside_root="${fake_bin}/outside-mounts"
  alias_root="${fake_bin}/mount-alias"
  _write_certbot_darwin_stubs "$fake_bin"
  : >"$docker_log_file"
  mkdir -p "$outside_root"
  printf 'outside sentinel\n' >"$outside_root/sentinel.key"
  chmod 777 "$outside_root"
  chmod 666 "$outside_root/sentinel.key"
  ln -s "$outside_root" "$alias_root"

  output="$(
    PATH="${fake_bin}:$PATH"
    export PATH CHOWN_MOCK_LOG_FILE="$docker_log_file"
    SUDO_UID=501 SUDO_GID=20
    unset STATE_DIR
    CERTS_DIR="$alias_root/missing-certs"
    ACME_WEBROOT_DIR="$alias_root/missing-acme"
    # shellcheck source=../../../lib/permissions/fix_permissions.sh
    source "$ROOT_DIR/lib/permissions/fix_permissions.sh"
    fix_permissions_certbot_darwin_user 2>&1
  )"
  status=$?

  assertTrue "directly sourced Darwin repair guards ancestors with STATE_DIR unset" "[ $status -ne 0 ]"
  assertStringContains "direct-source mount prefix guard" "symlinked runtime path component" "$output"
  assertFalse "direct-source rejection must not create certs" "[ -e '${outside_root}/missing-certs' ]"
  assertFalse "direct-source rejection must not create ACME webroot" "[ -e '${outside_root}/missing-acme' ]"
  assertEquals "direct-source outside directory mode remains unchanged" 777 "$(_certbot_test_mode "$outside_root")"
  assertEquals "direct-source outside key mode remains unchanged" 666 "$(_certbot_test_mode "$outside_root/sentinel.key")"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "direct-source mount alias"

  rm -rf "$fake_bin"
}

function test_fix_permissions_certbot_darwin_user_rejects_non_sudo_without_chown() {
  local fake_bin docker_log_file output status
  fake_bin="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-darwin-certbot-prep-nosudo.XXXXXX")"
  docker_log_file="${fake_bin}/docker.log"
  _write_certbot_darwin_stubs "$fake_bin"

  output="$(ID_MOCK_UID=501 _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    fix-permissions --certbot-darwin-user)"
  status=$?

  assertTrue "explicit Darwin Certbot prep should fail without sudo" "[ $status -ne 0 ]"
  assertStringContains "non-sudo rejection" "must be run with sudo" "$output"
  _assert_certbot_no_mount_ownership_mutation "$docker_log_file" "non-sudo explicit prep"

  rm -rf "$fake_bin"
}
