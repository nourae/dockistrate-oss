#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/config.sh"
source "$ROOT_DIR/lib/utils.sh"
source "$ROOT_DIR/lib/domain_config.sh"
TEST_WORK="$(mktemp -d "${TMPDIR:-/tmp}/domain-export-metadata.XXXXXXXX")"
trap 'rm -rf "$TEST_WORK"' EXIT
STATE_DIR="$TEST_WORK/state"
_domain_config_bind_config "$STATE_DIR/config"
mkdir -p "$CONFIG_DIR"
printf '1\n' >"$CONFIG_DIR/state_schema_version"
SKIP_DOCKER_CHECKS=false
MOCK_DOCKER_STATUS=0 MOCK_IDENTITY_STATUS=0 MOCK_IDENTITY_FOUND=1
MOCK_SNAPSHOT_STATUS=0 MOCK_IMAGE=nginx:alpine MOCK_STATE=running MOCK_VACANCY_STATUS=0

function docker() {
  [ "${1:-}" = info ] || return 1
  printf 'info\n' >>"$TEST_WORK/calls"
  return "$MOCK_DOCKER_STATUS"
}
function _backend_identity_read() {
  BACKEND_IDENTITY_FOUND="$MOCK_IDENTITY_FOUND"
  return "$MOCK_IDENTITY_STATUS"
}
function _backend_container_snapshot() {
  printf 'snapshot\n' >>"$TEST_WORK/calls"
  BACKEND_CONTAINER_IMAGE="$MOCK_IMAGE" BACKEND_CONTAINER_STATUS="$MOCK_STATE"
  return "$MOCK_SNAPSHOT_STATUS"
}
function _backend_cleanup_snapshot() {
  printf 'vacancy\n' >>"$TEST_WORK/calls"
  return "$MOCK_VACANCY_STATUS"
}
function metadata() {
  local _dc_domain=example.com _dc_destination="$TEST_WORK/exported" _dc_image="" _dc_state=""
  _domain_config_export_backend_metadata "${1:-}" || return 1
  csv_join_row "$_dc_image" "$_dc_state"
}
function reject_metadata() {
  if metadata "${1:-}" >"$TEST_WORK/rejected" 2>&1; then
    printf '[FAIL] accepted conflicting or unverified backend metadata\n' >&2; exit 1
  fi
}
function details() {
  printf 'domain,image,state\nexample.com,%s,%s\n' "$1" "$2" >"$TEST_WORK/details.csv"
}

[ "$(metadata)" = nginx:alpine,running ]
details nginx:other running
reject_metadata "$TEST_WORK/details.csv"
details nginx:alpine stopped
reject_metadata "$TEST_WORK/details.csv"
details nginx:alpine running
[ "$(metadata "$TEST_WORK/details.csv")" = nginx:alpine,running ]

MOCK_SNAPSHOT_STATUS=2
details nginx:alpine stopped
[ "$(metadata "$TEST_WORK/details.csv")" = nginx:alpine,stopped ]
MOCK_VACANCY_STATUS=1
reject_metadata "$TEST_WORK/details.csv"
MOCK_SNAPSHOT_STATUS=1 MOCK_IDENTITY_FOUND=0 MOCK_VACANCY_STATUS=0
[ "$(metadata "$TEST_WORK/details.csv")" = nginx:alpine,stopped ]
MOCK_VACANCY_STATUS=1
: >"$TEST_WORK/calls"
[ "$(metadata "$TEST_WORK/details.csv")" = nginx:alpine,stopped ]
! grep -Fq vacancy "$TEST_WORK/calls"
reject_metadata
printf 'domain,image,state\nother.example.com,nginx:alpine,stopped\n' >"$TEST_WORK/other-details.csv"
reject_metadata "$TEST_WORK/other-details.csv"
details nginx:alpine ''
reject_metadata "$TEST_WORK/details.csv"
details nginx:alpine stopped
MOCK_IDENTITY_FOUND=1 MOCK_VACANCY_STATUS=0
reject_metadata "$TEST_WORK/details.csv"
MOCK_IDENTITY_STATUS=1 MOCK_DOCKER_STATUS=1
reject_metadata "$TEST_WORK/details.csv"

MOCK_IDENTITY_STATUS=0
: >"$TEST_WORK/calls"
[ "$(metadata "$TEST_WORK/details.csv")" = nginx:alpine,stopped ]
! grep -Fq snapshot "$TEST_WORK/calls"
mkdir -p "$STATE_DIR/domains/example.com/runtime"
printf 'image,container_port,network,state\nnginx:alpine,,,\n' >"$STATE_DIR/domains/example.com/runtime/backend.csv"
reject_metadata
[ "$(metadata "$TEST_WORK/details.csv")" = nginx:alpine,stopped ]
_domain_runtime_put "$STATE_DIR/domains/example.com/runtime/backend.csv" state running
reject_metadata "$TEST_WORK/details.csv"

# Accepted current-schema specifications never depend on Docker availability.
printf '5\n' >"$CONFIG_DIR/state_schema_version"
: >"$TEST_WORK/calls"
[ "$(metadata)" = nginx:alpine,running ]
[ ! -s "$TEST_WORK/calls" ]
rm "$STATE_DIR/domains/example.com/runtime/backend.csv"
mkdir -p "$STATE_DIR/domains/example.com/runtime/applied"
printf 'image,container_port,network,state\nnginx:alpine,,,\n' >"$STATE_DIR/domains/example.com/runtime/applied/backend.csv"
[ "$(metadata)" = nginx:alpine,running ]
printf '[PASS] domain export metadata ownership and conflict checks\n'
