#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/http_version.sh
source "$ROOT_DIR/lib/http_version.sh"
# shellcheck source=../lib/headers.sh
source "$ROOT_DIR/lib/headers.sh"
# shellcheck source=../lib/security_rules.sh
source "$ROOT_DIR/lib/security_rules.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_override_validation.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
CONFIG_DIR="$TMP_ROOT/config"
mkdir -p "$CONFIG_DIR"
BACKEND_HTTP_FILE="$CONFIG_DIR/backend_http_versions.csv"
BACKEND_CLIENT_IP_HEADER_FILE="$CONFIG_DIR/backend_client_ip_headers.csv"
BACKEND_PROXY_IP_HEADER_FILE="$CONFIG_DIR/backend_proxy_ip_headers.csv"
BACKEND_ACL_POLICY_FILE="$CONFIG_DIR/backend_acl_policies.csv"
BACKEND_ACL_STATUS_FILE="$CONFIG_DIR/backend_acl_statuses.csv"
BACKEND_SECURITY_RULE_STATUS_FILE="$CONFIG_DIR/backend_security_rule_statuses.csv"
INHERITANCE_FILE="$CONFIG_DIR/dedicated_host_inheritance.csv"

function fail_test() {
  printf '[Error] %s\n' "$*" >&2
  exit 1
}

# Keep the domain relationship fixed while exercising the real file readers.
function backend_for_dedicated_host() {
  if [ "${1:-}" = host.example.com ]; then
    printf '%s\n' example.com
  fi
}

function expect_value() {
  local expected="$1" actual=""
  shift
  actual="$("$@")" || fail_test "Expected successful lookup: $*"
  [ "$actual" = "$expected" ] || fail_test "Unexpected lookup value for $*"
}

function expect_rejected() {
  local actual=""
  if actual="$("$@" 2>"$TMP_ROOT/error")"; then
    fail_test "Malformed state accepted by $*"
  fi
  [ -z "$actual" ] || fail_test "Rejected lookup emitted a fallback value: $*"
  [ -s "$TMP_ROOT/error" ] || fail_test "Rejected lookup omitted a diagnostic: $*"
}

# An absent override retains normal global behavior.
expect_value http2 get_backend_http_version example.com
expect_value 1.1 get_proxy_http_version example.com
expect_value X-Forwarded-For get_backend_client_ip_header example.com
expect_value X-Real-IP get_backend_proxy_ip_header example.com
expect_value deny get_backend_acl_policy example.com
expect_value 403 get_backend_acl_status example.com
expect_value 403 get_backend_security_rule_status example.com
expect_value yes get_dedicated_host_inheritance host.example.com mtls

# Exercise every override file, including corruption after a matching row.
for kind in http client proxy policy acl_status security_status; do
  case "$kind" in
  http)
    file="$BACKEND_HTTP_FILE" header="$STATE_BACKEND_HTTP_VERSIONS_HEADER"
    getter=get_backend_http_version valid=http1.0 invalid='http1.1;return 200;#'
    ;;
  client)
    file="$BACKEND_CLIENT_IP_HEADER_FILE" header="$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER"
    getter=get_backend_client_ip_header valid=X-Client-IP invalid='X-IP;return 200;#'
    ;;
  proxy)
    file="$BACKEND_PROXY_IP_HEADER_FILE" header="$STATE_BACKEND_PROXY_IP_HEADERS_HEADER"
    getter=get_backend_proxy_ip_header valid=X-Proxy-IP invalid='X-IP;return 200;#'
    ;;
  policy)
    file="$BACKEND_ACL_POLICY_FILE" header="$STATE_BACKEND_ACL_POLICIES_HEADER"
    getter=get_backend_acl_policy valid=deny invalid=invalid
    ACL_POLICY=allow
    ;;
  acl_status)
    file="$BACKEND_ACL_STATUS_FILE" header="$STATE_BACKEND_ACL_STATUSES_HEADER"
    getter=get_backend_acl_status valid=451 invalid='403;return 200;#'
    ;;
  security_status)
    file="$BACKEND_SECURITY_RULE_STATUS_FILE" header="$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER"
    getter=get_backend_security_rule_status valid=418 invalid='403;return 200;#'
    ;;
  esac
  printf '%s\n' "$header" "ExAmPlE.CoM,$valid" >"$file"
  expect_value "$valid" "$getter" example.com
  if [ "$kind" != http ]; then
    expect_value "$valid" "$getter" host.example.com
  fi
  printf '%s\n' "other.example.com,$invalid" >>"$file"
  expect_rejected "$getter" example.com
  printf '%s\n' "$header" "example.com,$valid,extra" >"$file"
  expect_rejected "$getter" example.com
  printf '%s\n' "$header" "example.com,$valid" 'other.example.com,"unfinished' >"$file"
  expect_rejected "$getter" example.com
  printf '%s\n' "$header" "example.com,$valid" "EXAMPLE.COM,$valid" >"$file"
  expect_rejected "$getter" example.com
  printf '%s\n' "$header" "example.com,$invalid" >"$file"
  expect_rejected "$getter" example.com
  rm -f "$file"
done

# Header disabling uses off in backend state and an empty global value.
printf '%s\n' "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" 'example.com,off' >"$BACKEND_CLIENT_IP_HEADER_FILE"
expect_value '' get_backend_client_ip_header example.com
expect_value '' get_backend_client_ip_header host.example.com
printf '%s\n' "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER" 'example.com,' >"$BACKEND_CLIENT_IP_HEADER_FILE"
expect_value '' get_backend_client_ip_header example.com
expect_value '' get_backend_client_ip_header host.example.com
CLIENT_IP_HEADER=''
expect_value '' get_backend_client_ip_header other.example.com
rm -f "$BACKEND_CLIENT_IP_HEADER_FILE"
CLIENT_IP_HEADER=X-Forwarded-For

# Validate effective globals even when direct library calls bypass load_config.
HTTP_VERSION='http1.1;return 200;#'
expect_rejected get_proxy_http_version example.com
HTTP_VERSION=http2
PROXY_IP_HEADER='X-Real-IP;return 200;#'
expect_rejected get_backend_proxy_ip_header example.com
PROXY_IP_HEADER=X-Real-IP
ACL_POLICY=invalid
expect_rejected get_backend_acl_policy example.com
ACL_POLICY=deny
ACL_STATUS='403;return 200;#'
expect_rejected get_backend_acl_status example.com
ACL_STATUS=403
SECURITY_RULE_STATUS=invalid
expect_rejected get_backend_security_rule_status example.com
SECURITY_RULE_STATUS=403

# Inheritance flags cannot silently turn malformed input into intentional no.
for field in 1 2 3 4 5; do
  flags=(yes yes yes yes yes)
  flags[$((field - 1))]=invalid
  {
    printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER"
    csv_join_row host.example.com "${flags[@]}"
  } >"$INHERITANCE_FILE"
  expect_rejected get_dedicated_host_inheritance host.example.com mtls
  status=0
  should_inherit_acl host.example.com >/dev/null 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail_test 'Invalid inheritance must differ from deliberate no'
  expect_rejected get_backend_acl_policy host.example.com
  expect_rejected get_backend_client_ip_header host.example.com
done
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'host.example.com,no,no,no,no,no' >"$INHERITANCE_FILE"
expect_value no get_dedicated_host_inheritance host.example.com mtls
status=0
should_inherit_mtls host.example.com || status=$?
[ "$status" -eq 1 ] || fail_test 'Deliberate no should return false, not a validation error'
printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" 'example.com,allow' >"$BACKEND_ACL_POLICY_FILE"
expect_value deny get_backend_acl_policy host.example.com
printf '%s\n' 'HOST.EXAMPLE.COM,yes,yes,yes,yes,yes' >>"$INHERITANCE_FILE"
expect_rejected get_dedicated_host_inheritance host.example.com mtls
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'host.example.com,yes,yes,yes,yes,yes' 'other.example.com,yes,yes,,yes,yes' >"$INHERITANCE_FILE"
expect_rejected get_dedicated_host_inheritance host.example.com mtls
printf '%s\n' 'wrong,header' >"$INHERITANCE_FILE"
expect_rejected get_dedicated_host_inheritance host.example.com mtls
: >"$INHERITANCE_FILE"
expect_rejected get_dedicated_host_inheritance host.example.com mtls
[ ! -s "$INHERITANCE_FILE" ] || fail_test 'Inheritance validation repaired a malformed empty file'
rm -f "$INHERITANCE_FILE"
mkdir "$INHERITANCE_FILE"
expect_rejected get_dedicated_host_inheritance host.example.com mtls
rmdir "$INHERITANCE_FILE"

# The security builder must propagate a rejected effective policy before output.
printf '%s\n' "$STATE_BACKEND_ACL_POLICIES_HEADER" 'example.com,deny,extra' >"$BACKEND_ACL_POLICY_FILE"
expect_rejected _build_security_ip_for_domain example.com
expect_rejected _build_security_ip_stream_for_domain example.com
before_policy="$ACL_POLICY"
if _sr_effective_acl_policy example.com allow >"$TMP_ROOT/value" 2>"$TMP_ROOT/error"; then
  fail_test 'ACL policy helper accepted a malformed override'
fi
[ "$ACL_POLICY" = "$before_policy" ] || fail_test 'Failed ACL lookup changed the caller global policy'
[ ! -s "$TMP_ROOT/value" ] || fail_test 'Failed ACL lookup emitted a fallback value'

printf '%s\n' 'persisted_override_validation.sh: PASS'
