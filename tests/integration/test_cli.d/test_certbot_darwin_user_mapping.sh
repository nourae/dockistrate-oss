#!/usr/bin/env bash

function _write_certbot_darwin_stubs() {
  local fake_bin="${1:-}"

  mkdir -p "$fake_bin"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'printf "%s\n" "${UNAME_MOCK_VALUE:-Darwin}"'
  } >"${fake_bin}/uname"
  chmod +x "${fake_bin}/uname"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'case "${1:-}" in'
    printf '%s\n' '  -u) printf "%s\n" "${ID_MOCK_UID:-0}" ;;'
    printf '%s\n' '  -g) printf "%s\n" "${ID_MOCK_GID:-0}" ;;'
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
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } >"${fake_bin}/chown"
  chmod +x "${fake_bin}/chown"
}

function _run_dockistrate_with_darwin_certbot_env() {
  local fake_bin="${1:-}"
  local docker_log_file="${2:-}"
  shift 2

  (
    cd "$ROOT_DIR" &&
      PATH="${fake_bin}:${MOCK_BIN_DIR}:$PATH" \
        SKIP_DOCKER_CHECKS="${SKIP_DOCKER_CHECKS:-true}" \
        DOCKER_MOCK_LOG_FILE="$docker_log_file" \
        CHOWN_MOCK_LOG_FILE="$docker_log_file" \
        UNAME_MOCK_VALUE="${UNAME_MOCK_VALUE:-Darwin}" \
        ID_MOCK_UID="${ID_MOCK_UID:-0}" \
        ID_MOCK_GID="${ID_MOCK_GID:-0}" \
        STAT_MOCK_UID="${STAT_MOCK_UID:-501}" \
        STAT_MOCK_GID="${STAT_MOCK_GID:-20}" \
        STAT_MOCK_MODE="${STAT_MOCK_MODE:-750}" \
        STAT_MOCK_NESTED_PATH="${STAT_MOCK_NESTED_PATH:-}" \
        STAT_MOCK_NESTED_UID="${STAT_MOCK_NESTED_UID:-0}" \
        STAT_MOCK_NESTED_GID="${STAT_MOCK_NESTED_GID:-0}" \
        STAT_MOCK_NESTED_MODE="${STAT_MOCK_NESTED_MODE:-750}" \
        SUDO_UID=501 \
        SUDO_GID=20 \
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

  assertTrue "${context} should not change Certbot mount ownership" \
    "! grep -Eq -- '^chown( |$)' '${docker_log_file}'"
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
  cert_dir="${CERTS_DIR}/letsencrypt/live/linux-standalone.example_443"
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

  integration_seed_managed_proxy >/dev/null
  assertEquals "seed managed nginx-proxy for non-Darwin webroot test" 0 $?

  output="$(UNAME_MOCK_VALUE=Linux _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert linux-webroot.example 443 letsencrypt)"
  status=$?

  assertEquals "add-cert webroot should preserve non-Darwin fallback behavior" 0 $status
  assertStringContains "non-Darwin webroot mode indicator" "Using webroot mode" "$output"
  assertStringContains "non-Darwin webroot letsencrypt placement message" "Let’s Encrypt cert placed" "$output"
  cert_dir="${CERTS_DIR}/letsencrypt/live/linux-webroot.example_443"
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
  assertStringContains "add-cert Darwin mapping failure should roll back transaction" "add_cert_darwin-root-owned-fail.example_443 failed. Rolled back." "$output"
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
  nested_file="${CERTS_DIR}/letsencrypt/archive/${domain}/privkey1.pem"
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
  le_symlink="${CERTS_DIR}/letsencrypt"
  nested_file="${le_symlink}/archive/${domain}/privkey1.pem"
  _write_certbot_darwin_stubs "$fake_bin"

  rm -rf "$le_symlink" "$real_le_root"
  mkdir -p "$CERTS_DIR" "${real_le_root}/archive/${domain}"
  ln -s "$real_le_root" "$le_symlink"
  printf 'old-private-key\n' >"${real_le_root}/archive/${domain}/privkey1.pem"

  output="$(STAT_MOCK_NESTED_PATH="$nested_file" STAT_MOCK_NESTED_UID=501 STAT_MOCK_NESTED_GID=20 STAT_MOCK_NESTED_MODE=400 \
    _run_dockistrate_with_darwin_certbot_env "$fake_bin" "$docker_log_file" \
    add-cert "$domain" 443 letsencrypt)"
  status=$?

  assertTrue "add-cert should fail closed when symlinked LE mount root contains an unwritable nested file" "[ $status -ne 0 ]"
  case "$output" in
  *"Refusing to run Darwin Certbot without host-user mapping"* | *"Refusing to use symlinked runtime path component"*) ;;
  *) fail "symlinked mount-root fail-closed error did not report a path/user-mapping guard: $output" ;;
  esac
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

  source_dir="${CERTS_DIR}/selfsigned/live/${domain}_9443"
  le_dir="${CERTS_DIR}/letsencrypt/live/${domain}_9443"
  mkdir -p "$le_dir"
  cp "${source_dir}/fullchain.pem" "${le_dir}/fullchain.pem"
  cp "${source_dir}/privkey.pem" "${le_dir}/privkey.pem"

  ports_file="${CONFIG_DIR}/backend_ports.csv"
  rewritten_file="${TMP_DIR}/backend_ports_darwin_renew.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,9443,8000,https,selfsigned/live/${domain}_9443,"*)
      printf '%s\n' "port,${domain},,,,,9443,8000,https,letsencrypt/live/${domain}_9443,no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

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

  source_dir="${CERTS_DIR}/selfsigned/live/${domain}_9443"
  le_dir="${CERTS_DIR}/letsencrypt/live/${domain}_9443"
  mkdir -p "$le_dir" "${CERTS_DIR}/letsencrypt/archive/${domain}_9443"
  cp "${source_dir}/fullchain.pem" "${le_dir}/fullchain.pem"
  cp "${source_dir}/privkey.pem" "${le_dir}/privkey.pem"
  archive_file="${CERTS_DIR}/letsencrypt/archive/${domain}_9443/privkey1.pem"
  printf 'old-private-key\n' >"$archive_file"

  ports_file="${CONFIG_DIR}/backend_ports.csv"
  rewritten_file="${TMP_DIR}/backend_ports_darwin_renew_nested.csv"
  : >"$rewritten_file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    "port,${domain},,,,,9443,8000,https,selfsigned/live/${domain}_9443,"*)
      printf '%s\n' "port,${domain},,,,,9443,8000,https,letsencrypt/live/${domain}_9443,no,off,,off,auto,,,,,," >>"$rewritten_file"
      ;;
    *)
      printf '%s\n' "$line" >>"$rewritten_file"
      ;;
    esac
  done <"$ports_file"
  mv "$rewritten_file" "$ports_file"

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
  existing_key="${CERTS_DIR}/letsencrypt/archive/existing.example/privkey1.pem"
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
  le_root="${CERTS_DIR}/letsencrypt"
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
  assertStringContains "explicit prep completion" "Prepared Darwin Certbot mounts for 501:20" "$output"
  assertTrue "explicit prep should chown the LE mount tree" \
    "grep -Eq -- '^chown 501:20 .*${le_root}' '${docker_log_file}'"
  assertTrue "explicit prep should chown the ACME webroot tree" \
    "grep -Eq -- '^chown 501:20 .*${acme_root}' '${docker_log_file}'"
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
  le_root="${CERTS_DIR}/letsencrypt"
  real_le_root="${TMP_DIR}/darwin-certbot-prep-real-letsencrypt"
  _write_certbot_darwin_stubs "$fake_bin"

  rm -rf "$le_root" "$real_le_root"
  mkdir -p "$CERTS_DIR" "$real_le_root"
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
  le_root="${CERTS_DIR}/letsencrypt"
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
  assertStringContains "explicit prep completion with nested symlink" "Prepared Darwin Certbot mounts for 501:20" "$output"
  assertTrue "explicit prep should not chown nested symlink target" \
    "! grep -Fq -- '${outside_file}' '${docker_log_file}'"
  assertEquals "nested symlink target mode should stay unchanged" "666" "$(_certbot_test_mode "$outside_file")"
  assertEquals "real private key should still be restricted" "600" "$(_certbot_test_mode "$private_key")"

  rm -rf "$fake_bin" "$le_root" "$acme_root" "$outside_dir"
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
