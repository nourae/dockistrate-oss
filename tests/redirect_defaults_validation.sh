#!/usr/bin/env bash
# Fixture paths are consumed by production; injection-shaped values are literal.
# shellcheck disable=SC2034,SC1091,SC2016
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/nginx/update_nginx_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/redirect-defaults-validation.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
CERTS_DIR="$TEST_WORK/certs"
mkdir -p "$CERTS_DIR/example.com"
failures=0

function validate_port() {
  local protocol="$1" flag="$2" code="$3" certificate=""
  [ "$protocol" != https ] || certificate=example.com
  _validate_port_row_for_render 2 example.com 38080 8080 "$protocol" "$certificate" no "$flag" "$code" off auto
}
function validate_path() {
  _validate_path_row_for_render 3 example.com /redirect '' 38080 inherit "$1" "$2" prefix 100 '' none - auto
}
function expect_valid() {
  local label="$1"
  shift
  if ! "$@" >"$TEST_WORK/output" 2>&1; then
    printf '[FAIL] Rejected %s\n' "$label" >&2
    cat "$TEST_WORK/output" >&2
    failures=$((failures + 1))
  fi
}
function expect_invalid() {
  local label="$1"
  shift
  if "$@" >"$TEST_WORK/output" 2>&1; then
    printf '[FAIL] Accepted %s\n' "$label" >&2
    failures=$((failures + 1))
  elif ! grep -q 'redirect' "$TEST_WORK/output"; then
    printf '[FAIL] Rejected %s for an unrelated reason\n' "$label" >&2
    cat "$TEST_WORK/output" >&2
    failures=$((failures + 1))
  fi
}

# Blank means a rendering default, and must not be accepted by the explicit
# code validator itself or by unrelated flag/protocol combinations.
expect_valid 'HTTP listener with its default code' validate_port http on ''
expect_valid 'path with an inherited/default code' validate_path on ''
for code in 301 302 308 302:38443 308:65535; do
  expect_valid "explicit listener code $code" validate_port http on "$code"
  expect_valid "explicit path code $code" validate_path on "$code"
done
for code in 200 307 999 :443 301: 308:0 308:65536 302:443:444 ' 301' '301 ' '301; return 200' '302:$host'; do
  expect_invalid "invalid listener code $code" validate_port http on "$code"
  expect_invalid "invalid path code $code" validate_path on "$code"
done
for flag in off ''; do
  expect_valid "HTTP listener redirect flag '$flag' without a code" validate_port http "$flag" ''
  expect_invalid "HTTP listener redirect flag '$flag' with an explicit code" validate_port http "$flag" 301
done
expect_invalid 'listener inherit flag' validate_port http inherit ''
for flag in off inherit ''; do
  expect_valid "path redirect flag '$flag' without a code" validate_path "$flag" ''
  expect_invalid "path redirect flag '$flag' with an explicit code" validate_path "$flag" 301
done
for protocol in https tcp udp; do
  expect_valid "$protocol without redirects" validate_port "$protocol" off ''
  expect_invalid "$protocol with an implicit redirect" validate_port "$protocol" on ''
  expect_invalid "$protocol with an explicit redirect" validate_port "$protocol" on 301
  expect_invalid "$protocol with a code but no redirect" validate_port "$protocol" off 301
done
if is_valid_redirect_code_spec ''; then
  printf '[FAIL] Explicit redirect-code validation accepted an empty value\n' >&2
  failures=$((failures + 1))
fi
[ "$failures" -eq 0 ] || exit 1
printf '[PASS] blank redirect defaults retain strict code, flag and protocol validation\n'
