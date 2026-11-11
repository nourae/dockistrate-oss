#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/http_version.sh"
source "$ROOT_DIR/lib/headers.sh"
source "$ROOT_DIR/lib/security_rules.sh"
source "$ROOT_DIR/lib/nginx/update_nginx_config.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate_override_cache.XXXXXX")"
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

function fail_test() { printf '[Error] %s\n' "$*" >&2; exit 1; }
function backend_for_dedicated_host() { :; }
function expect_value() {
  local expected="$1" actual=""
  shift
  actual="$("$@")" || fail_test "Lookup failed: $*"
  [ "$actual" = "$expected" ] || fail_test "Wrong lookup result: $*"
}
function expect_rejected() {
  local actual=""
  if actual="$("$@" 2>"$TMP_ROOT/error")"; then
    fail_test "Changed or invalid state accepted: $*"
  fi
  [ -z "$actual" ] || fail_test "Rejected lookup emitted a fallback: $*"
  [ -s "$TMP_ROOT/error" ] || fail_test "Rejected lookup omitted its diagnostic: $*"
}

expect_rejected _update_nginx_config_from_validated_settings

files=("$BACKEND_HTTP_FILE" "$BACKEND_CLIENT_IP_HEADER_FILE" "$BACKEND_PROXY_IP_HEADER_FILE"
  "$BACKEND_ACL_POLICY_FILE" "$BACKEND_ACL_STATUS_FILE" "$BACKEND_SECURITY_RULE_STATUS_FILE" "$INHERITANCE_FILE")
headers=("$STATE_BACKEND_HTTP_VERSIONS_HEADER" "$STATE_BACKEND_CLIENT_IP_HEADERS_HEADER"
  "$STATE_BACKEND_PROXY_IP_HEADERS_HEADER" "$STATE_BACKEND_ACL_POLICIES_HEADER"
  "$STATE_BACKEND_ACL_STATUSES_HEADER" "$STATE_BACKEND_SECURITY_RULE_STATUSES_HEADER" "$STATE_DEDICATED_HOST_INHERITANCE_HEADER")
values=(http1.0 X-Client-IP X-Proxy-IP allow 451 418 no,yes,no,yes,no)
getters=(get_backend_http_version get_backend_client_ip_header get_backend_proxy_ip_header
  get_backend_acl_policy get_backend_acl_status get_backend_security_rule_status get_dedicated_host_inheritance)

for ((kind = 0; kind < 7; kind++)); do
  printf '%s\n' "${headers[$kind]}" >"${files[$kind]}"
  for ((row = 1; row <= 12; row++)); do
    printf 'Node%s.Example.Com,%s\n' "$row" "${values[$kind]}" >>"${files[$kind]}"
  done
done

# Count actual complete validations across subshell getters. This verifies
# scaling deterministically instead of depending on a host-speed deadline.
eval "$(declare -f validate_backend_setting_file | sed '1s/validate_backend_setting_file/_original_validate_backend_setting_file/')"
eval "$(declare -f validate_dedicated_host_inheritance_state | sed '1s/validate_dedicated_host_inheritance_state/_original_validate_dedicated_host_inheritance_state/')"
function validate_backend_setting_file() {
  printf '%s\n' "$1" >>"$TMP_ROOT/backend-validations"
  _original_validate_backend_setting_file "$@"
}
function validate_dedicated_host_inheritance_state() {
  printf '%s\n' inheritance >>"$TMP_ROOT/inheritance-validations"
  _original_validate_dedicated_host_inheritance_state "$@"
}

# Exercise the real render entrypoint and scoped preflight; its callback is
# replaced only to avoid unrelated Nginx, filesystem, and Docker work here.
function _update_nginx_config_from_validated_settings() {
  local row=0 kind=0 domain=""
  for ((row = 1; row <= 12; row++)); do
    domain="node${row}.example.com"
    for ((kind = 0; kind < 6; kind++)); do
      expect_value "${values[$kind]}" "${getters[$kind]}" "$domain"
    done
    expect_value no get_dedicated_host_inheritance "$domain" mtls
    expect_value yes get_dedicated_host_inheritance "$domain" acl
    expect_value no get_dedicated_host_inheritance "$domain" security_rules
    expect_value yes get_dedicated_host_inheritance "$domain" headers
    expect_value no get_dedicated_host_inheritance "$domain" paths
  done
}
update_nginx_config
[ "$(wc -l <"$TMP_ROOT/backend-validations" | tr -d '[:space:]')" = 6 ] || fail_test 'Render revalidated an override file per lookup'
[ "$(wc -l <"$TMP_ROOT/inheritance-validations" | tr -d '[:space:]')" = 1 ] || fail_test 'Render revalidated inheritance per lookup'

# One row per file is sufficient for the following mutation matrix.
for ((kind = 0; kind < 7; kind++)); do
  printf '%s\n' "${headers[$kind]}" "node1.example.com,${values[$kind]}" >"${files[$kind]}"
done

function mutate_during_render() {
  local file="$1" getter="$2" change="$3"
  case "$change" in
  content) printf 'later.example.com,invalid\n' >>"$file" ;;
  same_size)
    printf X | dd of="$file" bs=1 count=1 conv=notrunc 2>/dev/null
    touch -r "$TMP_ROOT/saved" "$file"
    ;;
  newline) printf '\n' >>"$file" ;;
  missing) rm "$file" ;;
  directory) rm "$file"; mkdir "$file" ;;
  symlink) rm "$file"; ln -s "$TMP_ROOT/saved" "$file" ;;
  esac
  expect_rejected "$getter" node1.example.com mtls
}

# Same-size/mtime metadata caches would miss some mutations. Compare contents
# including trailing newlines, and distinguish regular files from symlinks.
for ((kind = 0; kind < 7; kind++)); do
  file="${files[$kind]}"
  cp -p "$file" "$TMP_ROOT/saved"
  for change in content same_size newline missing directory symlink; do
    _with_validated_render_settings mutate_during_render "$file" "${getters[$kind]}" "$change"
    if [ -d "$file" ] && [ ! -L "$file" ]; then rmdir "$file"; else rm -f "$file"; fi
    cp -p "$TMP_ROOT/saved" "$file"
  done
done

function create_during_render() {
  printf '%s\n' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" 'node1.example.com,http1.0' >"$BACKEND_HTTP_FILE"
  expect_rejected get_backend_http_version node1.example.com
}
cp "$BACKEND_HTTP_FILE" "$TMP_ROOT/saved"
rm "$BACKEND_HTTP_FILE"
_with_validated_render_settings create_during_render
cp "$TMP_ROOT/saved" "$BACKEND_HTTP_FILE"

function mark_render_called() { : >"$TMP_ROOT/render-called"; }
# A failed final-file validation must not expose a partially populated cache.
printf 'later.example.com,invalid,yes,yes,yes,yes\n' >>"$INHERITANCE_FILE"
expect_rejected _with_validated_render_settings mark_render_called
[ ! -e "$TMP_ROOT/render-called" ] || fail_test 'Renderer ran after failed preflight'
printf '%s\n' "$STATE_DEDICATED_HOST_INHERITANCE_HEADER" 'node1.example.com,yes,yes,yes,yes,yes' >"$INHERITANCE_FILE"
_with_validated_render_settings mark_render_called
[ -f "$TMP_ROOT/render-called" ] || fail_test 'Valid retry did not render'

# Every later render sees new valid state; a cache never outlives its scope.
printf '%s\r\n"NODE1.EXAMPLE.COM","http1.1"' "$STATE_BACKEND_HTTP_VERSIONS_HEADER" >"$BACKEND_HTTP_FILE"
_with_validated_render_settings expect_value http1.1 get_backend_http_version node1.example.com
expect_value http1.1 get_backend_http_version node1.example.com
printf '\nlater.example.com,invalid\n' >>"$BACKEND_HTTP_FILE"
_persisted_cache_ready=true
_persisted_cache_count=1
export _persisted_cache_ready _persisted_cache_count
expect_rejected get_backend_http_version node1.example.com

printf '%s\n' 'persisted_override_cache.sh: PASS'
