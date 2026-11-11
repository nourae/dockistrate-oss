#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dockistrate-directive-visibility.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

# shellcheck source=../lib/config.sh
source "$ROOT_DIR/lib/config.sh"
# shellcheck source=../lib/utils.sh
source "$ROOT_DIR/lib/utils.sh"
# shellcheck source=../lib/nginx_directives.sh
source "$ROOT_DIR/lib/nginx_directives.sh"
# shellcheck source=../lib/nginx/status.sh
source "$ROOT_DIR/lib/nginx/status.sh"

STATE_DIR="$TEST_DIR"
CONFIG_DIR="$TEST_DIR/config"
NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE="$TEST_DIR/generated/global.conf"
NGINX_DIRECTIVES_FILE="$CONFIG_DIR/nginx_directives.csv"
mkdir -p "$CONFIG_DIR"
MARKER=DUMMY_DIRECTIVE_SECRET
FAILURES=0

function fail_check() {
  printf '[Error] %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

function check_display() {
  local label="$1" output="$2" value="$3"
  if [ "$VISIBILITY_POLICY" = redacted ]; then
    case "$output" in
    *"$value"*) fail_check "$label leaked directive value" ;;
    esac
    case "$output" in
    *'[REDACTED]'*) ;;
    *) fail_check "$label missing redaction marker" ;;
    esac
  else
    case "$output" in
    *"$value"*) ;;
    *) fail_check "$label lost explicit full directive value" ;;
    esac
  fi
}

# Only unrelated runtime/transaction boundaries are replaced. Parsing,
# validation, CSV persistence, listing and success messages remain real.
function begin_transaction() { return 0; }
function end_transaction_success() { return 0; }
function update_nginx_config() { return 0; }
function _rollback_handler() { fail_check 'unexpected directive transaction failure'; exit 1; }
function nginx_directive_preflight_required_module() { return 0; }
function nginx_directives_resolve_scope_target() { return 0; }

for VISIBILITY_POLICY in redacted full; do
  for scope in global backend port path stream-global stream-backend stream-port; do
    case "$scope" in
    global | stream-global) target=("$scope") ;;
    backend | stream-backend) target=("$scope" example.com) ;;
    port | stream-port) target=("$scope" example.com 8443) ;;
    path) target=("$scope" example.com 8443 /api) ;;
    esac
    if [[ "$scope" == stream-* ]]; then
      directive=proxy_ssl_name
      value="$MARKER"
    else
      directive=proxy_set_header
      value="Authorization $MARKER"
    fi
    output="$(set_nginx_directive_raw "${target[@]}" "$directive" "$value")"
    check_display "$scope setter" "$output" "$MARKER"
    grep -Fq "$MARKER" "$NGINX_DIRECTIVES_FILE" || fail_check "$scope canonical state lost raw directive value"
  done
  check_display 'raw list' "$(list_nginx_directives)" "$MARKER"
  check_display 'raw status' "$(_status_print_nginx_directives)" "$MARKER"

  # A managed directive uses the same operator visibility guarantee.
  output="$(set_nginx_directive global client_max_body_size 37m)"
  check_display 'managed setter' "$output" 37m
  check_display 'managed list' "$(list_nginx_directives)" 37m
  grep -Fq 'client_max_body_size,37m' "$NGINX_DIRECTIVES_FILE" || fail_check 'canonical state lost managed directive value'

done

# Read-only display must neither replace secrets in storage nor alter file
# contents. Actual rendering must still send the full value to Nginx.
VISIBILITY_POLICY=redacted
cp "$NGINX_DIRECTIVES_FILE" "$TEST_DIR/before.csv"
list_nginx_directives >/dev/null
_status_print_nginx_directives >/dev/null
cmp -s "$TEST_DIR/before.csv" "$NGINX_DIRECTIVES_FILE" || fail_check 'display mutated canonical directive state'
nginx_directives_render_global_include
rendered="$(cat "$NGINX_DIRECTIVES_GLOBAL_INCLUDE_FILE")"
case "$rendered" in
*"proxy_set_header Authorization $MARKER;"*) ;;
*) fail_check 'Nginx configuration render lost actual header value' ;;
esac

[ "$FAILURES" -eq 0 ] || { printf '[Error] %s directive visibility assertions failed\n' "$FAILURES" >&2; exit 1; }
printf '[tests] raw_directive_visibility.sh: PASS\n'
