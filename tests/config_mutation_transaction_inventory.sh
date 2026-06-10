#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

allowlist=(
  "lib/backends/restart_all_backends.sh"
  "lib/backends/start_all_backends.sh"
  "lib/certs/_renew_letsencrypt_cert.sh"
  "lib/cli/run_command.sh"
  # Shared update helper; callers must remain transaction-wrapped.
  "lib/global_settings/common.sh"
  "lib/security_rules/common.sh"
)

function in_allowlist() {
  local candidate="$1"
  local entry=""
  for entry in "${allowlist[@]}"; do
    if [ "$entry" = "$candidate" ]; then
      return 0
    fi
  done
  return 1
}

function list_files_with_pattern() {
  local pattern="${1:-}"
  local file=""

  if command -v rg >/dev/null 2>&1; then
    rg -l "$pattern" lib | sort
    return 0
  fi

  while IFS= read -r file; do
    if grep -E -q "$pattern" "$file"; then
      printf '%s\n' "$file"
    fi
  done < <(find lib -type f -name '*.sh' | sort)
}

function file_has_pattern() {
  local pattern="${1:-}" file="${2:-}"
  if command -v rg >/dev/null 2>&1; then
    rg -q "$pattern" "$file"
    return $?
  fi
  grep -E -q "$pattern" "$file"
}

function first_match_line() {
  local pattern="${1:-}" file="${2:-}" line=""
  if command -v rg >/dev/null 2>&1; then
    line="$(rg -n -m 1 "$pattern" "$file" 2>/dev/null | cut -d: -f1 || true)"
  else
    line="$(grep -n -E "$pattern" "$file" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
  fi
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

function assert_assignment_after_transaction_start() {
  local file="${1:-}" assignment_pattern="${2:-}" begin_line="" assignment_line=""

  if ! begin_line="$(first_match_line "_config_begin_(return_)?transaction_if_needed|begin_transaction_return|begin_transaction" "$file")"; then
    fail_test "Missing transaction wrapper in ${file}"
  fi
  if ! assignment_line="$(first_match_line "$assignment_pattern" "$file")"; then
    fail_test "Missing reviewed assignment in ${file}"
  fi
  if [ "$assignment_line" -lt "$begin_line" ]; then
    fail_test "Assignment must occur after transaction start in ${file}"
  fi
}

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if in_allowlist "$file"; then
    continue
  fi
  if ! file_has_pattern "_config_begin_(return_)?transaction_if_needed|begin_transaction_return|begin_transaction|_mtls_begin_transaction_if_needed" "$file"; then
    fail_test "Missing transaction wrapper in ${file}"
  fi
done < <(list_files_with_pattern "update_nginx_config")

runtime_mutators=(
  "lib/global_settings/set_nginx_image.sh"
  "lib/global_settings/set_nginx_docker_opts.sh"
  "lib/nginx/start_nginx.sh"
)

for file in "${runtime_mutators[@]}"; do
  if ! file_has_pattern "_nginx_prepare_runtime_rollback" "$file"; then
    fail_test "Missing nginx runtime rollback hook in ${file}"
  fi
done

reviewed_assignment_guards=(
  "lib/global_settings/set_acl_status.sh|^[[:space:]]*ACL_STATUS="
  "lib/global_settings/set_security_rule_status.sh|^[[:space:]]*SECURITY_RULE_STATUS="
  "lib/global_settings/set_real_ip_recursive.sh|^[[:space:]]*REAL_IP_RECURSIVE="
  "lib/global_settings/set_trusted_proxies.sh|^[[:space:]]*TRUSTED_PROXY_RANGES="
  "lib/security_rules/set_acl_policy.sh|^[[:space:]]*ACL_POLICY="
  "lib/headers/set_client_ip_header.sh|^[[:space:]]*CLIENT_IP_HEADER="
  "lib/headers/set_proxy_ip_header.sh|^[[:space:]]*PROXY_IP_HEADER="
)

for entry in "${reviewed_assignment_guards[@]}"; do
  IFS='|' read -r file assignment_pattern <<<"$entry"
  assert_assignment_after_transaction_start "$file" "$assignment_pattern"
done

echo "config mutation transaction inventory checks passed."
