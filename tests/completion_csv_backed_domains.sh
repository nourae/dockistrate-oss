#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-completion-csv.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

BACKEND_CLIENT_IP_HEADER_FILE="$tmp_dir/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$tmp_dir/backend_proxy_ip_headers.csv"
BACKEND_HTTP_FILE="$tmp_dir/backend_http_versions.csv"
BACKEND_ACL_POLICY_FILE="$tmp_dir/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$tmp_dir/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$tmp_dir/backend_security_rule_statuses.csv"
BACKEND_HEADERS_FILE="$tmp_dir/backend_headers.csv"

seed_two_column_csv() {
  local file="$1" header="$2"
  printf '%s\n' \
    "$header" \
    'beta.example,"value,with,commas"' \
    'alpha.example,plain' \
    'beta.example,duplicate' >"$file"
}

seed_two_column_csv "$BACKEND_CLIENT_IP_HEADER_FILE" "domain,client_ip_header_name"
seed_two_column_csv "$BACKEND_PROXY_IP_HEADER_FILE" "domain,proxy_ip_header_name"
seed_two_column_csv "$BACKEND_HTTP_FILE" "domain,http_version"
seed_two_column_csv "$BACKEND_ACL_POLICY_FILE" "domain,acl_policy"
seed_two_column_csv "$BACKEND_ACL_STATUS_FILE" "domain,acl_status_code"
seed_two_column_csv "$BACKEND_SECURITY_RULE_STATUS_FILE" "domain,security_rule_status_code"

printf '%s\n' \
  'domain,header_type,header_name,header_value' \
  'beta.example,response,X-Test,"value,with,commas"' \
  'alpha.example,request,X-Alpha,plain' \
  'beta.example,request,X-Other,duplicate' >"$BACKEND_HEADERS_FILE"

__dockistrate_completion_handlers=()

# shellcheck source=../completion/commands/_dockistrate_complete_backend_file_commands.sh
source "$ROOT_DIR/completion/commands/_dockistrate_complete_backend_file_commands.sh"
# shellcheck source=../completion/commands/headers.sh
source "$ROOT_DIR/completion/commands/headers.sh"

fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

assert_domain_completion() {
  local handler="$1" command="$2"
  local expected="alpha.example beta.example"

  cur=""
  cword=2
  words=(dockistrate.sh "$command")
  COMPREPLY=()

  "$handler" "$command" || fail_test "$command completion was not handled"
  [ "${COMPREPLY[*]-}" = "$expected" ] ||
    fail_test "$command completion mismatch: expected '$expected', got '${COMPREPLY[*]-}'"
}

for command in \
  remove-backend-client-ip-header \
  remove-backend-proxy-ip-header \
  remove-backend-http-version \
  remove-backend-acl-policy \
  remove-backend-acl-status \
  remove-backend-security-rule-status; do
  assert_domain_completion _dockistrate_complete_backend_file_commands "$command"
done

for command in remove-backend-header list-backend-headers; do
  assert_domain_completion _dockistrate_complete_headers "$command"
done

echo "[tests] completion_csv_backed_domains.sh: PASS"
