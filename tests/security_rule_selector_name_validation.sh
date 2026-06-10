#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/state/config"
SECURITY_RULES_FILE="${CONFIG_DIR}/security_rules.csv"

function fail_test() {
  echo "[Error] $*" >&2
  exit 1
}

function run_cmd() {
  (cd "$ROOT_DIR" && SKIP_DOCKER_CHECKS=true ./dockistrate.sh "$@")
}

function expect_failure_contains() {
  local expected="$1"
  shift
  local output=""
  if output="$(run_cmd "$@" 2>&1)"; then
    fail_test "Expected command to fail: $*"
  fi
  case "$output" in
  *"$expected"*) ;;
  *)
    echo "$output" >&2
    fail_test "Expected failure output to contain: ${expected}"
    ;;
  esac
}

rm -rf "${ROOT_DIR}/state"
mkdir -p "${ROOT_DIR}/state"

run_cmd add-backend selector-validation.test nginx:alpine 18180 http --listen 18191 --no-expose >/dev/null

bad_arg_name='foo) { return 200; } #'
expect_failure_contains "invalid arg selector name" \
  add-security-rule selector-validation.test 1 arg "$bad_arg_name" equals bar

if [ -f "$SECURITY_RULES_FILE" ] && grep -Fq "$bad_arg_name" "$SECURITY_RULES_FILE"; then
  fail_test "Rejected selector name was written to security_rules.csv"
fi

run_cmd add-security-rule selector-validation.test 1 arg session_id equals abc >/dev/null

expect_failure_contains "invalid var selector name" \
  update-security-rule 1 --count 1 var bad-name equals abc

tmp_file="$(mktemp "${TMPDIR:-/tmp}/dockistrate_security_rules.XXXXXX")"
awk -F',' -v OFS=',' -v bad="$bad_arg_name" 'NR == 2 { $7 = bad } { print }' "$SECURITY_RULES_FILE" >"$tmp_file"
mv "$tmp_file" "$SECURITY_RULES_FILE"

expect_failure_contains "invalid arg selector name" update-nginx-config

echo "[tests] security_rule_selector_name_validation.sh: PASS"
