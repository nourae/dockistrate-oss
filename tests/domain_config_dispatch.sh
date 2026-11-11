#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/utils/validators.sh
source "$ROOT_DIR/lib/utils/validators.sh"
# shellcheck source=../lib/nginx_directives/common.sh
source "$ROOT_DIR/lib/nginx_directives/common.sh"
# shellcheck source=../lib/domain_config/dispatch.sh
source "$ROOT_DIR/lib/domain_config/dispatch.sh"

PENDING=example.com
GUARDED_DOMAINS=()
function domain_config_list() { printf 'example.com\nother.example.com\nalias.example.com\ndedicated.example.com\n'; }
function domain_config_root() { printf '/fixture/domains\n'; }
function domain_config_get() {
  case "$1" in
  */alias.example.com/runtime/applied | */dedicated.example.com/runtime/applied) printf 'example.com\n' ;;
  *) printf '\n' ;;
  esac
}
function primary_domain_for() {
  case "$1" in alias.example.com | dedicated.example.com) printf 'example.com\n' ;; *) printf '%s\n' "$1" ;; esac
}
function _domain_config_guard_pending() {
  GUARDED_DOMAINS+=("$1")
  [ "$1" != "$PENDING" ] || { DOMAIN_CONFIG_PENDING_DOMAIN="$1"; return 1; }
}
function assert_blocked() {
  if _domain_config_command_guard "$@"; then
    printf '[FAIL] Command ignored pending domain: %s\n' "$*" >&2; exit 1
  fi
  [ "${DOMAIN_CONFIG_PENDING_DOMAIN:-}" = "$PENDING" ]
}
function assert_targets() {
  local expected="$1"
  shift
  GUARDED_DOMAINS=()
  if ! _domain_config_command_guard "$@"; then
    printf '[FAIL] Unrelated pending files blocked command: %s\n' "$*" >&2; exit 1
  fi
  if [ "${GUARDED_DOMAINS[*]-}" != "$expected" ]; then
    printf '[FAIL] Wrong pending targets for %s: expected <%s>, got <%s>\n' "$*" "$expected" "${GUARDED_DOMAINS[*]-}" >&2; exit 1
  fi
}

assert_blocked set-nginx-directive backend EXAMPLE.COM client_max_body_size 1m
assert_blocked set-nginx-directive-raw path example.com 8080 /x add_header value
assert_blocked remove-nginx-directive stream-port example.com 9000 proxy_timeout
assert_blocked remove-all-nginx-directives
assert_blocked remove-all-nginx-directives all
assert_blocked renew-certs
assert_blocked remove-all-path-options
assert_blocked remove-all-backend-headers
assert_blocked remove-all-path-options EXAMPLE.COM
assert_blocked remove-all-backend-headers example.com
_domain_config_command_guard remove-all-path-options other.example.com
_domain_config_command_guard remove-all-backend-headers other.example.com
_domain_config_command_guard set-nginx-directive backend other.example.com client_max_body_size 1m
_domain_config_command_guard remove-all-nginx-directives global
_domain_config_command_guard set-nginx-directive stream-global proxy_timeout 60s

# Host-keyed changes only touch their own source. A parent draft must not block
# a dedicated host or an ordinary alias's independent headers/settings.
assert_targets alias.example.com add-backend-header ALIAS.EXAMPLE.COM response X-Example value
assert_targets alias.example.com update-backend-header alias.example.com response X-Example value
assert_targets alias.example.com remove-backend-header alias.example.com response X-Example
assert_targets dedicated.example.com set-backend-http-version dedicated.example.com http1.1
assert_targets dedicated.example.com set-backend-client-ip-header dedicated.example.com X-Forwarded-For
assert_targets dedicated.example.com remove-dedicated-host dedicated.example.com
assert_targets alias.example.com remove-host-alias alias.example.com
assert_targets dedicated.example.com set-nginx-directive backend dedicated.example.com client_max_body_size 1m
assert_targets new.example.com add-host-alias new.example.com example.com
assert_targets '' set-client-ip-header example.com
assert_targets '' set-proxy-ip-header example.com
assert_targets '' set-tls-ciphers example.com
assert_targets '' set-nginx-image example.com

# Parent-resolving commands must reject a pending parent through either name.
assert_blocked add-port alias.example.com 8080 80 http
assert_blocked add-path-option dedicated.example.com 8080 /path
assert_blocked start-backend alias.example.com
assert_blocked remove-backend --yes ALIAS.EXAMPLE.COM
assert_blocked remove-backend dedicated.example.com --yes

PENDING=alias.example.com
assert_blocked add-backend-header alias.example.com response X-Example value
assert_blocked remove-host-alias alias.example.com
assert_targets example.com add-port alias.example.com 8080 80 http
assert_targets example.com add-path-option alias.example.com 8080 /path
assert_targets example.com remove-all-path-options alias.example.com
# This existing bulk-header command also resolves to the primary domain.
assert_targets example.com remove-all-backend-headers alias.example.com
assert_targets example.com stop-backend alias.example.com
assert_targets example.com start-backend example.com
assert_targets example.com set-backend-http-version example.com http1.1

PENDING=dedicated.example.com
assert_blocked set-backend-http-version dedicated.example.com http1.1
assert_blocked remove-dedicated-host dedicated.example.com
assert_blocked set-nginx-directive backend dedicated.example.com client_max_body_size 1m
assert_targets example.com update-port dedicated.example.com 8080 80 http
assert_blocked remove-backend --yes alias.example.com
assert_blocked remove-backend example.com --yes
PENDING=none.example.com
assert_targets 'example.com alias.example.com dedicated.example.com' remove-backend --yes alias.example.com
PENDING=example.com

# Host-local request rules guard their named source and destination, including
# moves by numeric ID. Condition values and other option values are not targets.
source "$ROOT_DIR/lib/utils/csv.sh"
function _sr_load_line() { printf '1,alias.example.com\n'; }
assert_targets alias.example.com add-security-rule alias.example.com 1 path - equals /private
assert_targets dedicated.example.com add-security-rule dedicated.example.com 1 path - equals /private
assert_targets 'alias.example.com dedicated.example.com' update-security-rule 1 --domain DEDICATED.EXAMPLE.COM
assert_targets alias.example.com update-security-rule 1 --domain alias.example.com
assert_targets alias.example.com update-security-rule 1 --count 1 header X-Test equals --domain --reason dedicated.example.com
PENDING=dedicated.example.com
assert_blocked add-security-rule dedicated.example.com 1 path - equals /private
assert_blocked update-security-rule 1 --domain dedicated.example.com
PENDING=alias.example.com
assert_blocked update-security-rule 1 --domain dedicated.example.com
PENDING=example.com

# The menu must surface pending files before a no-domain bulk command runs,
# using the same production guard as CLI dispatch.
# shellcheck source=../lib/cli/review_domain_config.sh
source "$ROOT_DIR/lib/cli/review_domain_config.sh"
function domain_config_active() { return 0; }
CHOICE_INDEX=0
REVIEWED_DOMAIN=''
APPLIED_DOMAIN=''
CHOICES=()
function choose_option_with_context_status() {
  [ "$3" = domain-config-pending ]
  printf -v "$1" '%s' 0
  printf -v "$2" '%s' "${CHOICES[$CHOICE_INDEX]}"
  CHOICE_INDEX=$((CHOICE_INDEX + 1))
}
function review_command_before_run() {
  [ "$1" = apply-domain-config ] && [ "$2" = "$PENDING" ]
}
function apply_domain_config() {
  if [ "${2:-}" = --dry-run ]; then REVIEWED_DOMAIN="$1"; else APPLIED_DOMAIN="$1"; fi
}
for command in remove-all-path-options remove-all-backend-headers; do
  CHOICE_INDEX=0; CHOICES=(0 2); REVIEWED_DOMAIN=''; APPLIED_DOMAIN=''
  review_status=0
  _review_domain_config_pending "$command" || review_status=$?
  [ "$review_status" -eq 1 ] && [ "$REVIEWED_DOMAIN" = "$PENDING" ] && [ -z "$APPLIED_DOMAIN" ]
  CHOICE_INDEX=0; CHOICES=(1)
  review_status=0
  _review_domain_config_pending "$command" >/dev/null || review_status=$?
  [ "$review_status" -eq 2 ] && [ "$APPLIED_DOMAIN" = "$PENDING" ]
done
# The deferred render retains only a verified explicit replacement's scoped
# allowance; ordinary commands never inherit it from another command or shell.
source "$ROOT_DIR/lib/domain_config/publication.sh"
function update_nginx_config() { RENDER_IDENTITY_MIGRATION="$BACKEND_IDENTITY_MIGRATION"; }
DOMAIN_CONFIG_RENDER_REQUESTED=true
for command in update-backend update-nginx-config apply-domain-config; do
  DOMAIN_CONFIG_MUTATION_COMMAND="$command"
  for allowed in false true; do
    DOMAIN_CONFIG_BACKEND_IDENTITY_MIGRATION="$allowed"
    BACKEND_IDENTITY_MIGRATION=true
    _domain_config_activate_deferred_render
    expected=false
    if [ "$command" = update-backend ] && [ "$allowed" = true ]; then expected=true; fi
    [ "$RENDER_IDENTITY_MIGRATION" = "$expected" ] || {
      printf '[FAIL] Wrong identity migration allowance for %s: %s\n' "$command" "$allowed" >&2
      exit 1
    }
  done
done
printf '[PASS] Pending edits guard CLI/menu commands and deferred identity migration stays scoped\n'
